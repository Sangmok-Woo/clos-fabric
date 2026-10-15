#!/usr/bin/env bash
# Step 1 (Q1) — 리눅스 vxlan 이 ECN 을 옮기는가. 사용: q1-signal.sh [초=8]
# 스파인 병목을 건 상태에서 인캐스트를 흘리며 세 지점을 동시에 캡처해 ECN 2비트를 센다.
#   leaf1 eth1 out : 캡슐화 직후 — 바깥 ECN 과 그 안의 안쪽 ECN (v1 이 보낸 것)
#   leaf3 eth1 in  : 디캡 직전 — 스파인이 찍은 바깥 CE, 아직 안 바뀐 안쪽 ECN (tcpdump 는 tc ingress 보다 앞)
#   leaf3 eth4 out : 디캡 뒤 v3 로 가는 안쪽 헤더
# 변형: vxlan tos 기본(0) / inherit / 고정 0x20, 그리고 장애 1·2 를 건 상태
# 결과: data/q1-signal.csv, data/pcap/q1-*.pcap (앞 200개)
. "$(dirname "$0")/common.sh"
DUR=${1:-8}
OUT=$DATA/q1-signal.csv; mkdir -p "$DATA/pcap"
echo "variant,point,total,not_ect,ect1,ect0,ce,outer_tos_top" > "$OUT"

# 패킷 수. tcpdump 는 VXLAN 패킷을 바깥·안쪽 두 줄로 찍으므로 시각으로 시작하는 줄만 센다
pc() { tcpdump -nn -r "$@" 2>/dev/null | grep -c '^[0-9]'; }
settos() { for L in leaf1 leaf2 leaf4; do nsx $L ip link set $VX type vxlan tos "$1" || return 1; done; }

count() {   # count <pcap> <바이트식>  → 합계,00,01,10,11
  local f=$1 e=$2 t; t=$(pc "$f")
  printf '%s' "$t"
  for v in 0 1 2 3; do printf ',%s' "$(pc "$f" "($e)&3=$v")"; done
}
tostop() { tcpdump -nn -v -r "$1" -c 3000 2>/dev/null | grep '^[0-9]' | grep -o 'tos 0x[0-9a-f]*' | sort | uniq -c | sort -rn | head -1 | awk '{print $3}'; }

run() {   # run <변형 이름>
  local v=$1 W=$CAP/q1-$1; rm -rf "$W"; mkdir -p "$W"
  dx $RX pkill iperf3 2>/dev/null; sleep 0.3
  for s in $SENDERS; do dx $RX iperf3 -s -D -p ${PORT[$s]}; done; sleep 0.5
  nsx leaf1 tcpdump -i eth1 -Q out -s 96 -U -nn -w "$W/l1up.pcap" 'udp dst port 4789 and dst host 10.255.1.3' >/dev/null 2>&1 & local p1=$!
  nsx leaf3 tcpdump -i eth1 -Q in  -s 96 -U -nn -w "$W/l3up.pcap" 'udp dst port 4789' >/dev/null 2>&1 & local p2=$!
  nsx leaf3 tcpdump -i eth4 -Q out -s 96 -U -nn -w "$W/l3host.pcap" 'tcp and dst host 10.10.10.33 and greater 200' >/dev/null 2>&1 & local p3=$!
  sleep 1
  local m0; m0=$(nsx spine1 tc -s -j qdisc show dev eth3 | python3 -c 'import json,sys; print(sum(q.get("marked",0) for q in json.load(sys.stdin)))')
  for s in $SENDERS; do dx $s iperf3 -c $RX_IP -p ${PORT[$s]} -t $DUR >/dev/null 2>&1 & done
  wait $(jobs -p | grep -v -e "^$p1$" -e "^$p2$" -e "^$p3$")
  local m1; m1=$(nsx spine1 tc -s -j qdisc show dev eth3 | python3 -c 'import json,sys; print(sum(q.get("marked",0) for q in json.load(sys.stdin)))')
  sleep 1; kill $p1 $p2 $p3; sleep 0.5
  echo "$v,leaf1-up outer,$(count "$W/l1up.pcap" 'ip[1]'),$(tostop "$W/l1up.pcap")" >> "$OUT"
  echo "$v,leaf1-up inner,$(count "$W/l1up.pcap" 'udp[31]')," >> "$OUT"
  echo "$v,leaf3-up outer,$(count "$W/l3up.pcap" 'ip[1]'),$(tostop "$W/l3up.pcap")" >> "$OUT"
  echo "$v,leaf3-up inner,$(count "$W/l3up.pcap" 'udp[31]')," >> "$OUT"
  echo "$v,leaf3-host inner,$(count "$W/l3host.pcap" 'ip[1]')," >> "$OUT"
  echo "$v,spine1 red marked,$((m1 - m0)),,,,," >> "$OUT"
  for p in l1up l3up l3host; do tcpdump -r "$W/$p.pcap" -c 200 -w "$DATA/pcap/q1-$v-$p.pcap" 2>/dev/null; done
  echo "  $v: 바깥 CE(leaf3 앞) $(pc "$W/l3up.pcap" 'ip[1]&3=3') / 안쪽 CE(v3 앞) $(pc "$W/l3host.pcap" 'ip[1]&3=3') / 스파인 마킹 $((m1 - m0))"
}

say "Q1 변형별 캡처 (${DUR}초씩)"
settos 0;       run default
if settos inherit; then run tos-inherit; else echo "  tos inherit: 실행 중 변경 불가" | tee -a "$OUT"; fi
if settos 0x20;    then run tos-0x20;    else echo "  tos 0x20: 실행 중 변경 불가"    | tee -a "$OUT"; fi
settos 0
"$EXP/scripts/inject-decap.sh" on >/dev/null; run fault-decap; "$EXP/scripts/inject-decap.sh" off >/dev/null
"$EXP/scripts/inject-encap.sh" on >/dev/null; run fault-encap; "$EXP/scripts/inject-encap.sh" off >/dev/null
dx $RX pkill iperf3 2>/dev/null
echo "  vxlan tos 원복: $(dx leaf1 ip -d link show $VX | grep -o 'tos [a-z0-9]*' || echo '기본(0)')"
column -s, -t "$OUT"
