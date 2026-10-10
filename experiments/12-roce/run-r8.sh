#!/usr/bin/env bash
# R8 — ECN(신호) · DCQCN(규칙) · PFC(비상 브레이크)를 RoCE 인캐스트 위에 하나씩 얹는다.
#   g1·g2·g4 → g3 동시에 8초 (64KB 메시지). leaf3:eth5(→g3)를 300Mbit 포트로 묶은 게 병목이다 (R5 와 같은 자리)
#   A 기준(꼬리 드랍 64KB)  B ECN만  C ECN+DCQCN  D PFC만  E ECN+DCQCN+PFC  F E 와 같고 문턱 순서만 반대
# 같은 시간에 피해자 흐름 두 개를 흘린다 (RoCE 와 같은 클래스 DSCP 26, UDP 50Mbit):
#   V1 h1 → h3  leaf3 까지 같은 길이지만 내려가는 포트(eth3)는 한가하다
#   V2 h2 → h4  leaf3 를 아예 지나지 않는다. leaf2 업링크만 g2 와 같이 쓴다
# 캡처: leaf3:eth5 (병목 뒤, CE 도장이 찍힌 RoCE), leaf1:eth5 (g1 으로 돌아오는 CNP)
# 먼저: setup.sh (g1~g4 + rxe), ansible prep-hosts.yml (iperf3)
# 사용: run.sh            전부
#       run.sh C E        일부만
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=128
CAPDIR=$HERE/capture/r8   # R1~R7 의 capture/ 와 섞이지 않게
ST=$HERE/state/r8; mkdir -p "$CAPDIR" "$ST"
STEPS=${*:-A B C D E F}
[ $# -eq 0 ] && rm -rf "$CAPDIR"/*
exec > >(tee -a "$CAPDIR/run-output.txt") 2>&1

DUR=8
T() { docker exec rtool "$@"; }
cnt() { cat /sys/class/infiniband/rxe_$1/ports/1/hw_counters/$2; }
RT=$HERE/tools   # R8 도구 (dcqcn·pfc·summary)
TCQ() { local n=$1; shift; if [ "$n" = host ]; then tc "$@"; else nsx "$n" tc "$@"; fi; }

# ---------- 큐 만들기 ----------
# RoCE 클래스(DSCP 26 = tos 0x68, ECN 두 비트는 무시)만 plug 가 달린 줄로, 나머지는 다른 줄로.
# plug 는 평소에 열려 있다(release_indefinite). PFC 를 켠 시나리오에서만 pfc.py 가 닫았다 연다
class_queue() {   # class_queue <노드|host> <dev>  — 스파인·리프 업링크·h서버용 prio
  local n=$1 d=$2
  TCQ $n qdisc del dev $d root 2>/dev/null
  TCQ $n qdisc add dev $d root handle 1: prio bands 2 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
  TCQ $n qdisc add dev $d parent 1:1 handle 11: plug limit 33554432
  TCQ $n qdisc change dev $d parent 1:1 handle 11: plug release_indefinite
  TCQ $n qdisc add dev $d parent 1:2 handle 12: pfifo limit 10000
  TCQ $n filter add dev $d parent 1: protocol ip prio 1 u32 match ip dsfield 0x68 0xfc flowid 1:1
}
sender_queue() {  # sender_queue <N> — gN: RoCE 클래스는 htb 1:10(DCQCN 이 속도를 바꾼다) 아래 plug, 나머지는 1:20
  local d=g$1
  tc qdisc del dev $d root 2>/dev/null
  tc qdisc add dev $d root handle 1: htb default 20
  tc class add dev $d parent 1: classid 1:10 htb rate 1000mbit ceil 1000mbit quantum 60000
  tc class add dev $d parent 1: classid 1:20 htb rate 10gbit ceil 10gbit quantum 60000
  tc qdisc add dev $d parent 1:10 handle 11: plug limit 33554432
  tc qdisc change dev $d parent 1:10 handle 11: plug release_indefinite
  tc qdisc add dev $d parent 1:20 handle 12: pfifo limit 10000
  tc filter add dev $d parent 1: protocol ip prio 1 u32 match ip dsfield 0x68 0xfc flowid 1:10
}
bottleneck() {    # bottleneck <leaf qdisc 정의...> — leaf3:eth5 300Mbit, 그 아래 큐
  nsx leaf3 tc qdisc del dev eth5 root 2>/dev/null
  nsx leaf3 tc qdisc add dev eth5 root handle 1: htb default 10
  nsx leaf3 tc class add dev eth5 parent 1: classid 1:10 htb rate 300mbit ceil 300mbit quantum 60000
  nsx leaf3 tc qdisc add dev eth5 parent 1:10 handle 10: "$@"
}
q_stat() { nsx leaf3 tc -s -j qdisc show dev eth5 | python3 -c '
import json,sys
q=next(q for q in json.load(sys.stdin) if q.get("handle")=="10:")
print(q.get("drops",0), q.get("marked",0))'; }

pfc_config() {    # pfc_config <xoff> <xon> > json
  python3 - "$1" "$2" <<'EOF'
import json, sys
xoff, xon = int(sys.argv[1]), int(sys.argv[2])
racks = [1, 2, 4]
t = {}
for s in (1, 2):
    t[f"spine{s}:eth3"] = {"node": f"spine{s}", "dev": "eth3", "parent": "1:1"}
    for n in racks:
        t[f"leaf{n}:eth{s}"] = {"node": f"leaf{n}", "dev": f"eth{s}", "parent": "1:1"}
for n in racks:
    t[f"g{n}"] = {"node": "host", "dev": f"g{n}", "parent": "1:10"}
    t[f"h{n}"] = {"node": f"h{n}", "dev": "eth1", "parent": "1:1"}
w = [{"name": "leaf3:eth5", "node": "leaf3", "dev": "eth5", "handle": "10:", "xoff": xoff, "xon": xon,
      "targets": ["spine1:eth3", "spine2:eth3"]}]
for s in (1, 2):
    w.append({"name": f"spine{s}:eth3", "node": f"spine{s}", "dev": "eth3", "handle": "11:", "xoff": xoff, "xon": xon,
              "targets": [f"leaf{n}:eth{s}" for n in racks]})
    for n in racks:
        w.append({"name": f"leaf{n}:eth{s}", "node": f"leaf{n}", "dev": f"eth{s}", "handle": "11:", "xoff": xoff, "xon": xon,
                  "targets": [f"g{n}", f"h{n}"]})
print(json.dumps({"watch": w, "targets": t}, indent=1))
EOF
}

prepare() {
  for s in 1 2; do class_queue spine$s eth3; for n in 1 2 4; do class_queue leaf$n eth$s; done; done
  for n in 1 2 4; do class_queue h$n eth1; sender_queue $n; done
}

# ---------- 한 시나리오 ----------
# scen <id> <제목> <tclass> <dcqcn 0|1> <pfc xoff|0> <bottleneck 큐 정의...>
scen() {
  local id=$1 title=$2 tcl=$3 dc=$4 xoff=$5; shift 5
  local L=$CAPDIR/$id; mkdir -p "$L"
  say "$id  $title"
  prepare
  bottleneck "$@"
  echo "  병목 큐: $*   RoCE tclass=$tcl (ECN 비트 $((tcl & 3)))   DCQCN=$dc   PFC XOFF=$xoff"
  local pids=()
  [ "$dc" = 1 ] && { python3 "$RT/dcqcn.py" np "$L" & pids+=($!); python3 "$RT/dcqcn.py" rp "$L" & pids+=($!); }
  [ "$xoff" != 0 ] && { pfc_config "$xoff" $((xoff / 2)) > "$L/pfc-config.json"; python3 "$RT/pfc.py" "$L/pfc-config.json" "$L" & pids+=($!); }
  cap_start $id-leaf3-eth5 leaf3 eth5 udp port 4791
  [ "$dc" = 1 ] && cap_start $id-leaf1-eth5-cnp leaf1 eth5 udp port 4792
  cap_wait 1
  local b3; b3=$(cnt g3 out_of_seq_request)
  declare -A r0; for n in 1 2 4; do r0[$n]=$(cnt g$n completer_retry_err); done

  # 피해자 흐름: RoCE 와 같은 클래스(tos 0x68)의 UDP 50Mbit
  docker exec clab-clos-h3 sh -c 'timeout 20 iperf3 -s -1 -p 5201 >/dev/null 2>&1' &
  docker exec clab-clos-h4 sh -c 'timeout 20 iperf3 -s -1 -p 5202 >/dev/null 2>&1' &
  sleep 1
  local wl=()
  docker exec clab-clos-h1 iperf3 -c 172.16.13.10 -p 5201 -u -b 50M -S 104 -t $DUR -J > "$L/v1.json" 2>/dev/null & wl+=($!)
  docker exec clab-clos-h2 iperf3 -c 172.16.14.10 -p 5202 -u -b 50M -S 104 -t $DUR -J > "$L/v2.json" 2>/dev/null & wl+=($!)
  # 같은 병목 큐를 지나는 ping. DSCP 0 이라 PFC 클래스는 아니고, ECT(0)를 켠다(-Q 0x02):
  # ECN 큐는 ECT 가 없는 패킷을 도장 대신 버리므로, 안 켜면 큐가 깊을 때의 ping 만 골라 사라진다
  ping -I vg1 -Q 0x02 -i 0.05 -c $((DUR * 20)) -W 1 -q 172.16.23.10 > "$L/ping.txt" 2>&1 & wl+=($!)
  # 병목 큐 깊이를 20ms 마다 직접 잰다
  ( P3=$(pid leaf3); end=$(( $(date +%s) + DUR + 5 ))
    while [ "$(date +%s)" -lt $end ]; do
      nsenter -t $P3 -n tc -s -j qdisc show dev eth5
      echo; sleep 0.02
    done > "$L/qdepth.jsonl" ) & wl+=($!)

  # RoCE 인캐스트: 받는 쪽 서버 셋, 보내는 쪽 셋
  local p=18530
  for n in 1 2 4; do
    T sh -c "timeout $((DUR + 15)) ib_write_bw -d rxe_g3 -x 1 -p $((p + n)) -s 65536 -D $DUR -F --tclass=$tcl > /tmp/r8-$n.txt 2>&1" &
  done
  sleep 1.5
  for n in 1 2 4; do
    timeout -s KILL $((DUR + 15)) docker exec rtool ib_write_bw -d rxe_g$n -x 1 -p $((p + n)) -s 65536 -D $DUR -F \
      --tclass=$tcl --report_gbits 127.0.0.1 > "$L/bw-g$n.txt" 2>&1 & wl+=($!)
  done
  wait "${wl[@]}" 2>/dev/null

  # 도구에 끝내라고 하고(통계를 파일로 남긴다), 5초 안에 안 끝나면 강제로
  if [ ${#pids[@]} -gt 0 ]; then
    kill -TERM "${pids[@]}"
    alive() { local p; for p in "${pids[@]}"; do kill -0 $p 2>/dev/null && return 0; done; return 1; }
    for i in $(seq 50); do alive || break; sleep 0.1; done
    alive && { kill -9 "${pids[@]}" 2>/dev/null; echo "  (경고) 도구가 5초 안에 끝나지 않아 강제 종료 — 통계 일부가 없을 수 있다"; }
    wait "${pids[@]}" 2>/dev/null
  fi
  cap_stop >/dev/null
  read drops marked < <(q_stat)
  pkill -9 -f 'ib_write_bw' 2>/dev/null

  # ---------- 결과 한 줄씩 ----------
  local tot=0
  printf "  처리량       "
  for n in 1 2 4; do
    local g; g=$(awk '/^ *[0-9]+ +[0-9]+ /{v=$4} END{print (v==""?0:v)}' "$L/bw-g$n.txt")
    g=$(awk -v g="$g" 'BEGIN{print g * 1000}'); printf "g%s %4.0f  " $n "$g"; tot=$(awk -v a="$tot" -v b="$g" 'BEGIN{print a + b}')
  done
  printf "합 %.0f Mbit (포트 300)\n" "$tot"
  echo "  병목 큐     드랍 $drops   CE 도장 $marked"
  echo "  RoCE 재전송  g3 NAK $(( $(cnt g3 out_of_seq_request) - b3 ))   송신측 재시도 $(for n in 1 2 4; do echo -n "$(( $(cnt g$n completer_retry_err) - ${r0[$n]} )) "; done)"
  echo "  ping g1→g3  $(awk '/rtt/{split($4,a,"/"); printf "평균 %sms 최대 %sms", a[2], a[3]} /packet loss/{for(i=1;i<=NF;i++) if($i ~ /%/) l=$i} END{printf "  손실 %s", l}' "$L/ping.txt")"
  python3 "$RT/summary.py" "$L"
}

restore_all() { "$HERE/restore.sh" r8 >/dev/null 2>&1; }

A() { scen A "기준 — 꼬리 드랍, 버퍼 64KB" 104 0 0 bfifo limit 65536; }
# 문턱은 진짜 스위치보다 크다. 흉내 DCQCN·PFC 는 ms 단위로 반응하는데, 인캐스트가 시작되면 큐가 1ms 에 약 340KB 씩 찬다
ECN_LOW="red limit 4000000 min 100000 max 300000 avpkt 4200 burst 25 probability 0.5 bandwidth 300mbit ecn"
ECN_HIGH="red limit 4000000 min 1500000 max 3000000 avpkt 4200 burst 360 probability 0.5 bandwidth 300mbit ecn"
XOFF=1048576
B() { scen B "ECN만 — 도장은 찍지만 아무도 반응하지 않는다 (ECN 100~300KB)" 106 0 0 $ECN_LOW; }
C() { scen C "ECN + DCQCN — 도장을 보고 송신자가 속도를 줄인다 (ECN 100~300KB)" 106 1 0 $ECN_LOW; }
D() { scen D "PFC만 — 버리지 않고 한 홉 앞을 멈춘다 (XOFF 1MB)" 104 0 $XOFF bfifo limit 4000000; }
E() { scen E "ECN + DCQCN + PFC — ECN 문턱(100~300KB) < XOFF(1MB)" 106 1 $XOFF $ECN_LOW; }
F() { scen F "순서 반대 — ECN 문턱(1.5~3MB) > XOFF(1MB)" 106 1 $XOFF $ECN_HIGH; }

for s in $STEPS; do $s; sleep 3; done
restore_all
for f in "$CAPDIR"/*.pcap; do head_pcap "$f" 3000; done
W=$WINROOT/$(basename "$HERE")/capture/r8
[ -d "$WINROOT" ] && { rm -rf "$W"; mkdir -p "$W"; cp -r "$CAPDIR"/. "$W/"; }
true
