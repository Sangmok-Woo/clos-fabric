#!/usr/bin/env bash
# 실험 18 — VXLAN 바깥 DSCP 소실: 언더레이 QoS 가 RoCE 를 못 알아본다
#   16 장 2회차 Step 1: vxlan tos 0(기본)이면 안쪽 DSCP 26(RoCE)이 바깥에서 0 이 된다.
#   스파인은 바깥 헤더만 보고 큐를 고르므로, RoCE 가 전용 클래스 대신 TCP 대량 전송과 같은 줄에 선다.
#
#   병목 spine1:eth3 egress 300Mbit (htb). 클래스 1:10 = 바깥 DSCP 26 (보장 200Mbit, 우선순위 0)
#                                          1:20 = 나머지      (보장 100Mbit, 우선순위 1), 각 버퍼 256KB
#   g1 → g3 RoCE (tclass 106 = DSCP 26 + ECT0)   +   g2·g4 → g3 TCP cubic 4흐름씩 (DSCP 0)
#   S0 RoCE 혼자 / S1 tos 0(기본) / S2 tos inherit / S3 tos 0x68(고정) — 각각 처리량 30초 × 3회 + 지연 측정
#   g1 의 RoCE 는 송신측(xg1)에서 ROCE_RATE(기본 150Mbit, burst 작게)로 묶는다. rxe 는 혼잡 제어가 없어 그대로 두면
#   혼자서도 256KB 버퍼를 넘쳐 무너진다(첫 시도 S0: 64Mbit, 드랍 14만 — first-try-output.txt). 실제 RoCE NIC 의
#   DCQCN 이 맞춰 놓았을 '자기 몫 안의 속도'를 흉내 내는 것이고, 그래야 클래스 분류의 효과만 남는다
# 먼저: experiments/_wip/16-roce-vxlan-ecn/run2/scripts/setup.sh (g1~g4 VNI 10010 + rxe, 경로 spine1 고정)
# 사용: run.sh [S0 S1 S2 S3]
set -u
. "$(dirname "$0")/../16-roce-vxlan-ecn/run2/scripts/common.sh"
H=$(cd "$(dirname "$0")" && pwd)
OUT=$H/capture; mkdir -p "$OUT"
STEPS=${*:-S0 S1 S2 S3}
[ $# -eq 0 ] && rm -rf "$OUT"/*
exec > >(tee -a "$OUT/run-output.txt") 2>&1
DUR=30; REPS=3; ROCE_RATE=${ROCE_RATE:-150mbit}

qos_on() {
  local d=eth3
  nsx spine1 tc qdisc del dev $d root 2>/dev/null
  nsx spine1 tc qdisc add dev $d root handle 1: htb default 20
  nsx spine1 tc class add dev $d parent 1: classid 1:1 htb rate 300mbit ceil 300mbit quantum 60000
  nsx spine1 tc class add dev $d parent 1:1 classid 1:10 htb rate 200mbit ceil 300mbit prio 0 quantum 60000
  nsx spine1 tc class add dev $d parent 1:1 classid 1:20 htb rate 100mbit ceil 300mbit prio 1 quantum 60000
  nsx spine1 tc qdisc add dev $d parent 1:10 handle 10: bfifo limit 262144
  nsx spine1 tc qdisc add dev $d parent 1:20 handle 20: bfifo limit 262144
  nsx spine1 tc filter add dev $d parent 1: protocol ip prio 1 u32 match ip dsfield 0x68 0xfc flowid 1:10
}
# 클래스별 바이트·드랍 → "c10_bytes c10_drops c20_bytes c20_drops"
cls() { nsx spine1 tc -s -j qdisc show dev eth3 | python3 -c '
import json,sys
q={x["handle"]:x for x in json.load(sys.stdin)}
print(*[q.get(h,{}).get(k,0) for h in ("10:","20:") for k in ("bytes","drops")])'; }

bulk_tcp() {   # bulk_tcp <초> <접두어> — g2·g4 → g3 cubic 4흐름씩, DSCP 0
  local n
  for n in 2 4; do T timeout $(($1 + 15)) iperf3 -s -1 -p 540$n --bind-dev vr3 >/dev/null 2>&1 & done
  sleep 0.7
  for n in 2 4; do
    timeout $(($1 + 15)) docker exec rtool iperf3 -c $(ip_of 3) -p 540$n --bind-dev vr$n -C cubic -P 4 -t $1 -J > "$2-g$n.json" 2>/dev/null &
  done
}
tcp_sum() { python3 -c '
import json,sys
t=0
for f in sys.argv[1:]:
    try: t+=json.load(open(f))["end"]["sum_received"]["bits_per_second"]/1e6
    except Exception: pass
print(f"{t:.0f}")' "$@"; }

pace_roce() {  # xg1 의 RoCE 클래스(DSCP 26)를 ROCE_RATE 로, burst 는 패킷 몇 개 (실험 12 R5: burst 가 크면 소용없다)
  sender_queue 1
  tc class change dev xg1 parent 1: classid 1:10 htb rate $ROCE_RATE ceil $ROCE_RATE burst 15k cburst 15k quantum 60000
}

scen() {   # scen <id> <tos> <tcp 0|1> <제목>
  local id=$1 tos=$2 load=$3 L=$OUT/$1; mkdir -p "$L"
  say "$id  $4"
  vx_tos $tos; qos_on; pace_roce
  echo "  RoCE 송신 속도 제한 $ROCE_RATE (xg1)"
  # 바깥 DSCP 표본: spine1:eth3 에서 RoCE·TCP 200개씩
  nsenter -t "$(pid spine1)" -n tcpdump -i eth3 -s 128 -U -nn -c 400 -w "$L/spine1-eth3.pcap" udp port 4789 >/dev/null 2>&1 & local cp=$!
  echo "rep,roce_mbit,tcp_mbit,nak,retry,c10_MB,c10_drop,c20_MB,c20_drop" > "$L/bw.csv"
  for r in $(seq $REPS); do
    qos_on
    local n0 r0; n0=$(cnt 3 out_of_seq_request); r0=$(cnt 1 completer_retry_err)
    [ $load = 1 ] && { bulk_tcp $((DUR + 3)) "$L/tcp-r$r"; sleep 2; }
    T sh -c "timeout $((DUR + 15)) ib_write_bw -d rxe_x3 -x 1 -p 18701 -s 65536 -D $DUR -F --tclass=106 >/dev/null 2>&1" &
    sleep 1.5
    timeout -s KILL $((DUR + 15)) docker exec rtool ib_write_bw -d rxe_x1 -x 1 -p 18701 -s 65536 -D $DUR -F --tclass=106 \
      --report_gbits $OOB > "$L/bw-r$r.txt" 2>&1
    wait 2>/dev/null; pkill -9 -f 'ib_write_bw -d rxe_x' 2>/dev/null
    local bw; bw=$(awk '/^ *[0-9]+ +[0-9]+ /{v=$4} END{printf "%.0f", (v==""?0:v)*1000}' "$L/bw-r$r.txt")
    local tcp=0; [ $load = 1 ] && tcp=$(tcp_sum "$L"/tcp-r$r-g*.json)
    read b10 d10 b20 d20 < <(cls)
    local nak=$(( $(cnt 3 out_of_seq_request) - n0 )) rt=$(( $(cnt 1 completer_retry_err) - r0 ))
    printf "  r%s  RoCE %4s Mbit  TCP %4s Mbit │ NAK %5s 재시도 %5s │ 클래스10(DSCP26) %5sMB 드랍 %6s │ 클래스20(BE) %5sMB 드랍 %6s\n" \
      $r $bw $tcp $nak $rt $((b10 / 1000000)) $d10 $((b20 / 1000000)) $d20
    echo "$r,$bw,$tcp,$nak,$rt,$((b10 / 1000000)),$d10,$((b20 / 1000000)),$d20" >> "$L/bw.csv"
    sleep 2
  done
  kill $cp 2>/dev/null
  echo "  바깥 TOS 표본 (spine1:eth3):"; python3 "$EXP/scripts/tos.py" "$L/spine1-eth3.pcap" | sed 's/^/     /'
  # 지연: 64B RDMA Write 왕복, 같은 짐(TCP)을 얹고
  qos_on
  [ $load = 1 ] && { bulk_tcp 25 "$L/lat-tcp"; sleep 2; }
  T sh -c "timeout 40 ib_write_lat -d rxe_x3 -x 1 -p 18702 -s 64 -n 20000 -F --tclass=106 >/dev/null 2>&1" &
  sleep 1.5
  timeout -s KILL 40 docker exec rtool ib_write_lat -d rxe_x1 -x 1 -p 18702 -s 64 -n 20000 -F --tclass=106 $OOB > "$L/lat.txt" 2>&1
  wait 2>/dev/null; pkill -9 -f 'ib_write_lat -d rxe_x' 2>/dev/null
  awk '/^ *64 +20000/{printf "  지연 64B RDMA Write (µs)  min %s  typical %s  avg %s  99%% %s  99.9%% %s  max %s\n", $3, $5, $6, $8, $9, $4}' "$L/lat.txt"
}

S0() { scen S0 0 0 "기준 — RoCE 혼자 (짐 없음, tos 0)"; }
S1() { scen S1 0 1 "tos 0 (기본) — 바깥 DSCP 0: RoCE 가 TCP 와 같은 BE 클래스로"; }
S2() { scen S2 inherit 1 "tos inherit — 안쪽 DSCP 26 을 바깥으로: RoCE 만 클래스 10"; }
S3() { scen S3 0x68 1 "tos 0x68 (고정) — 모든 VXLAN 이 DSCP 26: TCP 도 클래스 10 으로"; }

date
for s in $STEPS; do $s; done
vx_tos 0
nsx spine1 tc qdisc del dev eth3 root 2>/dev/null
tc qdisc del dev xg1 root 2>/dev/null
for f in "$OUT"/*/*.pcap; do head_pcap "$f" 400; done
date
