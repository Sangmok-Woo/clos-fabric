#!/usr/bin/env bash
# 실험 19 — VXLAN 의 ECMP 엔트로피: 바깥 헤더는 VTEP 쌍 하나
#   오버레이 흐름이 아무리 많아도 바깥 IP 는 leaf1(10.255.1.1) → leaf3(10.255.1.3) 한 쌍이다.
#   스파인을 고르는 건 leaf1 의 해시인데, 베이스 패브릭은 fib_multipath_hash_policy=0(L3) 이다.
#   vxlan 은 안쪽 흐름의 해시로 바깥 UDP 출발 포트를 바꿔 엔트로피를 싣는다 — 그걸 해시가 보는가.
#
#   leaf1 업링크 eth1(→spine1)·eth2(→spine2) 를 각각 200Mbit 로 묶는다 (두 길 합 400)
#   P0 정책 0 / P1 정책 1 / P3 정책 3(5-튜플)  × TCP 8흐름  → 링크별 흐름 수, 합계 처리량
#   E  정책 1 에서 큰 흐름 2개 × 20회: 둘이 같은 스파인에 부딪히는 비율과 그때 처리량
#   Q  정책 1 에서 RoCE QP 1/2/4/8 (rxe 는 QP 마다 UDP 출발 포트가 다르다)
#   S  정책 1 + vxlan srcport 범위를 한 개로 좁힘 → 엔트로피 0
#   N  정책 1 + 네 리프 vxlan tos inherit — 커널 vxlan_get_route 는 tos 가 0 이 아니면 dst_cache 를 안 쓴다.
#      그러면 흐름마다 경로를 새로 찾아 출발 포트 해시가 먹는가 (TCP 8흐름 + 큰 흐름 2개 × 10회)
#   C  정책 1, TCP 1흐름씩 12번 — 매번 leaf1 의 경로 캐시를 비우고(ip route flush cache) 보낸다.
#      P1 에서 흐름 8개가 전부 한 링크로 간 것이 vxlan 의 dst_cache(원격 VTEP 마다 경로 하나를 캐시) 때문인지 가린다
# 먼저: experiments/_wip/16-roce-vxlan-ecn/run2/scripts/setup.sh. 18 이 내려 둔 spine2:eth3 은 이 장에서만 올렸다가 되돌린다
# 사용: run.sh [P0 P1 P3 E Q S]
set -u
. "$(dirname "$0")/../16-roce-vxlan-ecn/run2/scripts/common.sh"
H=$(cd "$(dirname "$0")" && pwd)
OUT=$H/capture; mkdir -p "$OUT" "$H/state"
STEPS=${*:-P0 P1 P3 E Q S C}
[ $# -eq 0 ] && rm -rf "$OUT"/*
exec > >(tee -a "$OUT/run-output.txt") 2>&1
G1=$(ip_of 1); G3=$(ip_of 3)

# ---------- 준비: 두 길 다 열고, 원래 값 기억 ----------
[ -f "$H/state/policy" ] || dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_policy > "$H/state/policy"
[ -f "$H/state/fields" ] || dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_fields > "$H/state/fields"
if [ -f "$EXP/state/spine2-eth3-down" ]; then
  nsx spine2 ip link set eth3 up
  touch "$H/state/spine2-raised"
fi
for i in $(seq 60); do
  [ "$(dx leaf1 ip route show 10.255.1.3 | grep -c nexthop)" = 2 ] && break; sleep 1
done
echo "leaf1 → leaf3 VTEP: $(dx leaf1 ip route show 10.255.1.3 | tr -s ' \n' ' ')"

uplinks() {
  for d in eth1 eth2; do
    nsx leaf1 tc qdisc del dev $d root 2>/dev/null
    nsx leaf1 tc qdisc add dev $d root handle 1: htb default 10
    nsx leaf1 tc class add dev $d parent 1: classid 1:10 htb rate 200mbit ceil 200mbit quantum 60000
    nsx leaf1 tc qdisc add dev $d parent 1:10 handle 10: bfifo limit 262144
  done
}
policy() { dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_policy=$1; [ -n "${2:-}" ] && dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_fields=$2; true; }
bytes() { nsx leaf1 tc -s -j qdisc show dev $1 | python3 -c 'import json,sys; print(sum(q["bytes"] for q in json.load(sys.stdin) if q.get("handle")=="10:"))'; }
capboth() {   # capboth <이름> — 업링크 둘을 동시에 (패킷당 앞 128B)
  local P; P=$(pid leaf1)
  nsenter -t $P -n tcpdump -i eth1 -s 128 -U -nn -w "$OUT/$1-eth1.pcap" udp port 4789 >/dev/null 2>&1 & c1=$!
  nsenter -t $P -n tcpdump -i eth2 -s 128 -U -nn -w "$OUT/$1-eth2.pcap" udp port 4789 >/dev/null 2>&1 & c2=$!
  sleep 0.7
}
capstop() { sleep 0.5; kill $c1 $c2 2>/dev/null; sleep 0.3; }
mapflows() {  # mapflows <이름> → 데이터 흐름(패킷 200개 이상)만 링크별로 세서 한 줄
  python3 "$H/flows.py" "$OUT/$1-eth1.pcap" "$OUT/$1-eth2.pcap" $G1 > "$OUT/$1-flows.txt"
  awk '$4 >= 200 {c[$2]++} END {printf "spine1 %d · spine2 %d · 둘다 %d", c["eth1"], c["eth2"], c["both"]}' "$OUT/$1-flows.txt"
}

tcpN() {      # tcpN <흐름 수> <초> <json> — g1 → g3 iperf3 -P N
  T timeout $(($2 + 15)) iperf3 -s -1 -p 5501 --bind-dev vr3 >/dev/null 2>&1 &
  sleep 0.7
  timeout $(($2 + 15)) docker exec rtool iperf3 -c $G3 -p 5501 --bind-dev vr1 -P $1 -t $2 -J > "$3" 2>/dev/null
  python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["end"]["sum_received"]["bits_per_second"]/1e6))' "$3" 2>/dev/null || echo 0
}

# P: 정책별 TCP 8흐름 10초
pol_run() {   # pol_run <id> <정책> [fields]
  say "$1  정책 $2${3:+ fields $3} — g1 → g3 TCP 8흐름 10초, 업링크 각 200Mbit"
  uplinks; policy $2 ${3:-}
  local b1 b2; b1=$(bytes eth1); b2=$(bytes eth2)
  capboth $1
  local t; t=$(tcpN 8 10 "$OUT/$1-iperf.json")
  capstop
  local e1=$(( ($(bytes eth1) - b1) / 1000000 )) e2=$(( ($(bytes eth2) - b2) / 1000000 ))
  echo "  합계 $t Mbit   eth1(spine1) ${e1}MB   eth2(spine2) ${e2}MB   흐름: $(mapflows $1)"
  echo "$1,$2,${3:-},$t,$e1,$e2,$(mapflows $1 | tr -dc '0-9 ' | tr -s ' ' ',')" >> "$OUT/policy.csv"
  for f in "$OUT/$1"-eth*.pcap; do head_pcap "$f" 300; done
}
P0() { pol_run P0 0; }
P1() { pol_run P1 1; }
P3() { pol_run P3 3 0x37; }

# E: 큰 흐름 둘 — 출발 포트만 바꿔 20번
E() {
  say "E  정책 1 — 큰 흐름 2개(각각 다른 iperf3)를 20번, 출발 포트만 새로"
  uplinks; policy 1
  echo "trial,cport_a,cport_b,link_a,link_b,mbit_a,mbit_b" > "$OUT/elephant.csv"
  local same=0 tot_same=0 tot_split=0 nsame=0 nsplit=0
  for k in $(seq 20); do
    local pa=$((20000 + RANDOM % 20000)) pb=$((40001 + RANDOM % 20000))
    for p in 5511 5512; do T timeout 20 iperf3 -s -1 -p $p --bind-dev vr3 >/dev/null 2>&1 & done
    sleep 0.7
    capboth e
    timeout 20 docker exec rtool iperf3 -c $G3 -p 5511 --cport $pa --bind-dev vr1 -t 5 -J > $OUT/e-a.json 2>/dev/null &
    timeout 20 docker exec rtool iperf3 -c $G3 -p 5512 --cport $pb --bind-dev vr1 -t 5 -J > $OUT/e-b.json 2>/dev/null
    wait %% 2>/dev/null; sleep 0.3
    capstop
    python3 "$H/flows.py" "$OUT/e-eth1.pcap" "$OUT/e-eth2.pcap" $G1 > "$OUT/e-flows.txt"
    local la lb ma mb
    la=$(awk -v p=$pa '$1==p{print $2}' "$OUT/e-flows.txt"); lb=$(awk -v p=$pb '$1==p{print $2}' "$OUT/e-flows.txt")
    ma=$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["end"]["sum_received"]["bits_per_second"]/1e6))' $OUT/e-a.json 2>/dev/null || echo 0)
    mb=$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["end"]["sum_received"]["bits_per_second"]/1e6))' $OUT/e-b.json 2>/dev/null || echo 0)
    echo "$k,$pa,$pb,$la,$lb,$ma,$mb" >> "$OUT/elephant.csv"
    printf "  %2d  흐름A :%-5s → %-4s %3s Mbit   흐름B :%-5s → %-4s %3s Mbit   합 %3s %s\n" $k $pa "$la" $ma $pb "$lb" $mb $((ma + mb)) "$([ "$la" = "$lb" ] && echo '← 충돌')"
  done
  rm -f $OUT/e-*.pcap $OUT/e-*.json
  python3 - "$OUT/elephant.csv" <<'PY'
import csv, sys
r = list(csv.DictReader(open(sys.argv[1])))
s = [x for x in r if x["link_a"] == x["link_b"] and x["link_a"]]
d = [x for x in r if x["link_a"] != x["link_b"] and x["link_a"] and x["link_b"]]
avg = lambda L: sum(int(x["mbit_a"]) + int(x["mbit_b"]) for x in L) / len(L) if L else 0
print(f"  충돌 {len(s)}/{len(r)}회 (합 평균 {avg(s):.0f} Mbit)   갈림 {len(d)}/{len(r)}회 (합 평균 {avg(d):.0f} Mbit)")
PY
}

# Q: RoCE QP 수
Q() {
  say "Q  정책 1 — RoCE g1 → g3, QP 1·2·4·8개 (64KB, 10초)"
  uplinks; policy 1
  echo "qps,mbit,flows_spine1,flows_spine2,eth1_MB,eth2_MB" > "$OUT/roce-qp.csv"
  for q in 1 2 4 8; do
    local b1 b2; b1=$(bytes eth1); b2=$(bytes eth2)
    T sh -c "timeout 30 ib_write_bw -d rxe_x3 -x 1 -p 18801 -q $q -s 65536 -D 10 -F --tclass=106 >/dev/null 2>&1" &
    sleep 1.5
    capboth q$q
    timeout -s KILL 30 docker exec rtool ib_write_bw -d rxe_x1 -x 1 -p 18801 -q $q -s 65536 -D 10 -F --tclass=106 --report_gbits $OOB > "$OUT/q$q-bw.txt" 2>&1
    capstop; wait 2>/dev/null; pkill -9 -f 'ib_write_bw -d rxe_x' 2>/dev/null
    local bw; bw=$(awk '/^ *[0-9]+ +[0-9]+ /{v=$4} END{printf "%.0f", (v==""?0:v)*1000}' "$OUT/q$q-bw.txt")
    local e1=$(( ($(bytes eth1) - b1) / 1000000 )) e2=$(( ($(bytes eth2) - b2) / 1000000 ))
    local m; m=$(mapflows q$q)
    echo "  QP $q  $bw Mbit   eth1 ${e1}MB  eth2 ${e2}MB   QP(안쪽 UDP 출발 포트): $m"
    echo "$q,$bw,$(echo $m | awk '{print $2","$5}'),$e1,$e2" >> "$OUT/roce-qp.csv"
    for f in "$OUT"/q$q-eth*.pcap; do head_pcap "$f" 300; done
    sleep 2
  done
}

# S: vxlan 출발 포트 범위를 한 개로
S() {
  say "S  정책 1 + leaf1 vxlan srcport 49152-49153 (바깥 출발 포트 하나뿐)"
  local cur; cur=$(dx leaf1 ip -d link show vni$VNI | grep -o 'srcport [0-9]* [0-9]*')
  echo "  지금: $cur"
  if dx leaf1 ip link set vni$VNI type vxlan srcport 49152 49153 2>"$OUT/s-err.txt"; then
    echo "  바꿈: $(dx leaf1 ip -d link show vni$VNI | grep -o 'srcport [0-9]* [0-9]*')"
    pol_run S 1
    dx leaf1 ip link set vni$VNI type vxlan srcport 0 0
    echo "  되돌림: $(dx leaf1 ip -d link show vni$VNI | grep -o 'srcport [0-9]* [0-9]*')"
  else
    echo "  실행 중에는 못 바꾼다: $(cat "$OUT/s-err.txt")"
  fi
}

N() {
  vx_tos inherit
  pol_run N 1
  local same=0 n=10
  for k in $(seq $n); do
    local pa=$((20000 + RANDOM % 20000)) pb=$((40001 + RANDOM % 20000))
    for p in 5511 5512; do T timeout 20 iperf3 -s -1 -p $p --bind-dev vr3 >/dev/null 2>&1 & done
    sleep 0.7; capboth te
    timeout 20 docker exec rtool iperf3 -c $G3 -p 5511 --cport $pa --bind-dev vr1 -t 4 -J > $OUT/te-a.json 2>/dev/null &
    timeout 20 docker exec rtool iperf3 -c $G3 -p 5512 --cport $pb --bind-dev vr1 -t 4 -J > $OUT/te-b.json 2>/dev/null
    wait %% 2>/dev/null; sleep 0.3; capstop
    python3 "$H/flows.py" "$OUT/te-eth1.pcap" "$OUT/te-eth2.pcap" $G1 > "$OUT/te-flows.txt"
    local la lb ma mb
    la=$(awk -v p=$pa '$1==p{print $2}' "$OUT/te-flows.txt"); lb=$(awk -v p=$pb '$1==p{print $2}' "$OUT/te-flows.txt")
    ma=$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["end"]["sum_received"]["bits_per_second"]/1e6))' $OUT/te-a.json 2>/dev/null || echo 0)
    mb=$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["end"]["sum_received"]["bits_per_second"]/1e6))' $OUT/te-b.json 2>/dev/null || echo 0)
    [ "$la" = "$lb" ] && same=$((same + 1))
    printf "  %2d  A :%-5s → %-4s %3s   B :%-5s → %-4s %3s   합 %3s %s
" $k $pa "$la" $ma $pb "$lb" $mb $((ma + mb)) "$([ "$la" = "$lb" ] && echo '← 충돌')"
  done
  echo "  tos inherit 큰 흐름 2개: 충돌 $same/$n"
  rm -f $OUT/te-*.pcap $OUT/te-*.json
  vx_tos 0
}

C() {
  say "C  정책 1 — TCP 1흐름 × 12번, 매번 leaf1 경로 캐시 비우기 (flush=1) / 안 비우기 (flush=0)"
  uplinks; policy 1
  echo "flush,trial,sport,link" > "$OUT/cache.csv"
  for fl in 0 1; do
    local c1n=0 c2n=0
    for k in $(seq 12); do
      [ $fl = 1 ] && nsx leaf1 ip route flush cache
      T timeout 15 iperf3 -s -1 -p 5521 --bind-dev vr3 >/dev/null 2>&1 &
      sleep 0.5
      capboth c
      timeout 15 docker exec rtool iperf3 -c $G3 -p 5521 --bind-dev vr1 -t 1 -J > $OUT/c.json 2>/dev/null
      capstop
      local sp; sp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["start"]["connected"][0]["local_port"])' $OUT/c.json 2>/dev/null)
      python3 "$H/flows.py" "$OUT/c-eth1.pcap" "$OUT/c-eth2.pcap" $G1 > "$OUT/c-flows.txt"
      local l; l=$(awk -v p=$sp '$1==p{print $2}' "$OUT/c-flows.txt")
      [ "$l" = eth1 ] && c1n=$((c1n + 1)); [ "$l" = eth2 ] && c2n=$((c2n + 1))
      echo "$fl,$k,$sp,$l" >> "$OUT/cache.csv"
      wait 2>/dev/null
    done
    echo "  캐시 비우기 $fl: spine1 $c1n · spine2 $c2n (12흐름)"
  done
  rm -f $OUT/c-*.pcap $OUT/c.json
}

date
[ -f "$OUT/policy.csv" ] || echo "id,policy,fields,mbit,eth1_MB,eth2_MB,flows_s1,flows_s2,flows_both" > "$OUT/policy.csv"
for s in $STEPS; do $s; done
"$H/restore.sh"
date
