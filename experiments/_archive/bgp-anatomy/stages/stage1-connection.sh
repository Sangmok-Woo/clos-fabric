#!/bin/bash
# 1단계 — 연결: 세션이 태어나는 순간, 그리고 두 가지 방식으로 망가뜨리기.
# 비유: 전화를 걸고(SYN), 받고(SYN-ACK), "여보세요"(OPEN) 하는 과정.
set -u; cd "$(dirname "$0")/.."; . ./lib.sh
OUT=capture/stage1.txt; : > "$OUT"; exec > >(tee -a "$OUT") 2>&1
L=r100 R=r200    # r100 eth1 ─ r200 eth1 (10.1.2.1 ↔ 10.1.2.2)
LIP=10.1.2.1 RIP=10.1.2.2

say "1-0 정상 세션의 탄생 — TCP 3-way → OPEN → KEEPALIVE → Established"
cap_start s1-birth $L eth1 "tcp port 179 or (tcp port 179)"
vt $L "clear bgp 10.1.2.2"          # r100↔r200 세션만 리셋
printf '%s FSM 관찰(최대 12초): ' "$(ts)"
for i in $(seq 1 12); do
  st=$(vt $L "show bgp neighbor 10.1.2.2 json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["10.1.2.2"]["bgpState"])' 2>/dev/null)
  printf '%s ' "$st"; [ "$st" = Established ] && break; sleep 1
done; echo
cap_stop
echo "→ capture/s1-birth.pcap : SYN, SYN-ACK, ACK, OPEN×2, KEEPALIVE×2 가 순서대로 보인다"
nsx $L tcpdump -nn -r capture/s1-birth.pcap -c 12 2>/dev/null | sed 's/^/   /'

say "1-A 전화선 끊기 — TCP 179 를 DROP 하면 Connect/Active 에서 맴돈다"
nsx $L iptables -A OUTPUT -p tcp --dport 179 -d $RIP -j DROP
nsx $L iptables -A OUTPUT -p tcp --sport 179 -d $RIP -j DROP
nsx $L iptables -A INPUT  -p tcp --dport 179 -s $RIP -j DROP
nsx $L iptables -A INPUT  -p tcp --sport 179 -s $RIP -j DROP
vt $L "clear bgp 10.1.2.2"; sleep 8
echo "$(ts) r100 가 본 세션 상태:"
vt $L "show bgp neighbor 10.1.2.2 json" | python3 -c 'import json,sys;d=json.load(sys.stdin)["10.1.2.2"];print("   state =",d["bgpState"]," (Established 아님 = 전화가 안 걸림)")'
nsx $L iptables -F; vt $L "clear bgp 10.1.2.2"; wait_up 40 >/dev/null; echo "   필터 제거 → 복구"

say "1-B 잘못 건 전화 — 한쪽 remote-as 를 틀리면 OPEN 받자마자 NOTIFICATION(Bad Peer AS)"
cap_start s1-badas $L eth1 "tcp port 179"
cfg $L "router bgp 100" "neighbor 10.1.2.2 remote-as 999"   # 200 이어야 하는데 999
vt $L "clear bgp 10.1.2.2"; sleep 4
cap_stop
echo "$(ts) r100 이 본 마지막 리셋 사유:"
vt $L "show bgp neighbor 10.1.2.2" | grep -iE 'last reset|notification|peer as' | head -3 | sed 's/^/   /'
echo "→ capture/s1-badas.pcap : OPEN 교환 직후 NOTIFICATION(OPEN Message Error / Bad Peer AS)"
nsx $L tcpdump -v -nn -r capture/s1-badas.pcap 2>/dev/null | grep -iE 'bgp|notif' | tail -4 | sed 's/^/   /'
cfg $L "router bgp 100" "neighbor 10.1.2.2 remote-as 200"   # 원복
vt $L "clear bgp 10.1.2.2"; wait_up 40 >/dev/null
say "1단계 끝 — 세션 원복"; ./world.sh >/dev/null && echo OK
