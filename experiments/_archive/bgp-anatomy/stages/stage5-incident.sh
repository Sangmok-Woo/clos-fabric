#!/bin/bash
# 5단계 — 사고: 인터넷이 속는 방식. 배포 전에 예측하고, world.sh 실측과 비교한다.
set -u; cd "$(dirname "$0")/.."; . ./lib.sh
OUT=capture/stage5.txt; : > "$OUT"; exec > >(tee -a "$OUT") 2>&1
V=203.0.113.0/24

say "5-a 동일 프리픽스 하이재킹 — AS666 이 피해자와 똑같은 $V 를 광고"
echo "[예측] 666 에 가까운 AS(300·100·666)는 가짜로, 400 쪽에 가까운 500·400 은 진짜로."
hijack_add r666 10.3.6.1 $V
echo "[실측]"; ./world.sh $V
echo "데이터플레인 확인 — h100 의 패킷이 진짜 주인(r500) 대신 공격자(r666)에게 가 닿나:"
cap_start s5a-r666 r666 eth1 "icmp"
sleep 3; dx h100 ping -c5 -W1 203.0.113.10 >/dev/null 2>&1
cap_stop
echo "   r666 eth1 에 도착한 203.0.113.10 행 ICMP:"
nsx r666 tcpdump -nn -r capture/s5a-r666.pcap 2>/dev/null | grep -c '203.0.113.10' | sed 's/^/   /'
echo "   (0 이 아니면 데이터플레인이 가짜 경로를 따라 r666 으로 샜다는 뜻. r666 은 그걸 버린다=블랙홀)"
hijack_del r666 10.3.6.1 $V

say "5-b 더 구체적인 프리픽스 — AS666 이 /25 두 개를 광고"
echo "[예측] best path 는 같은 프리픽스끼리만 비교하지만, FIB 는 가장 긴 프리픽스를 따른다."
echo "       → /24 best 는 그대로 500 이어도, 실제 패킷은 /25(666)로 샌다. 거의 전 세계가."
hijack_add r666 10.3.6.1 203.0.113.0/25 203.0.113.128/25
echo "[실측] /24 best 는 여전히:"; ./world.sh $V | grep -E 'r100|r300'
echo "       그러나 /25 는 666 이 가져간다:"; ./world.sh 203.0.113.0/25 | grep -E 'r100|r300|r666'
echo "데이터플레인 — /24 best 는 500 이지만 FIB 는 더 긴 /25 를 따라 r666 으로:"
cap_start s5b-r666 r666 eth1 "icmp"
sleep 3; dx h100 ping -c5 -W1 203.0.113.10 >/dev/null 2>&1
cap_stop
echo "   r666 eth1 도착 ICMP(203.0.113.10):"
nsx r666 tcpdump -nn -r capture/s5b-r666.pcap 2>/dev/null | grep -c '203.0.113.10' | sed 's/^/   /'
hijack_del r666 10.3.6.1 203.0.113.0/25 203.0.113.128/25

say "5-c 경로 유출 — AS100 이 r200 에게 받은 프로바이더 경로를 r300 에게 그대로 재광고"
echo "[예측] r300 입장에선 그게 '고객(AS100) 경로'(LP 200) → 자기 프로바이더 경로보다 우선."
echo "       → 큰 트래픽이 조그만 AS100 으로 몰린다. Gao-Rexford 가 사고를 키우는 구조."
echo "[주입] r100→r300 아웃바운드를 밸리프리(TO-UP)에서 전부광고(TO-CUST)로 바꿔 유출을 만든다."
cfg r100 "router bgp 100" "address-family ipv4 unicast" "neighbor 10.1.3.2 route-map TO-CUST out"
vt r100 "clear bgp 10.1.3.2 soft out"; sleep 4
echo "[실측] r300 이 $V 를 AS100 경유(고객 LP200)로 보게 되나:"
vt r300 "show bgp ipv4 unicast $V json" | python3 -c '
import json,sys;ps=json.load(sys.stdin).get("paths",[])
b=[p for p in ps if p.get("bestpath",{}).get("overall")]
print("   r300 best:", (b[0]["aspath"]["string"] if b else "-"),"LP", (b[0].get("locPrf") if b else "-"))
print("   후보 all:", [ (p["aspath"]["string"], p.get("locPrf")) for p in ps ])'
./world.sh $V | grep -E 'r300|r400|r500'
cfg r100 "router bgp 100" "address-family ipv4 unicast" "neighbor 10.1.3.2 route-map TO-UP out"
vt r100 "clear bgp 10.1.3.2 soft out"; sleep 3

say "5-d 출처 위조 — AS666 이 AS_PATH 끝에 500 을 붙여 '500 한테 받았어요'인 척 (666 500)"
echo "[예측] 데이터플레인 결과는 5-a 와 비슷하지만, 출처 AS 가 500 으로 보여 6단계 RPKI 를 통과한다."
# r666 의 r300 쪽 out 을 FORGE(끝에 500 prepend)로 바꾸고 하이재킹
cfg r666 "route-map FORGE permit 10" "set as-path prepend 500"
cfg r666 "router bgp 666" "address-family ipv4 unicast" "neighbor 10.3.6.1 route-map FORGE out"
hijack_add r666 10.3.6.1 $V
echo "[실측] 가짜 경로의 as-path 와 출처(origin 이 500 으로 보인다):"
./world.sh $V | grep -E 'r100|r300'
hijack_del r666 10.3.6.1 $V
cfg r666 "router bgp 666" "address-family ipv4 unicast" "no neighbor 10.3.6.1 route-map FORGE out"
cfg r666 "no route-map FORGE"; vt r666 "clear bgp 10.3.6.1 soft out"; sleep 3

say "5단계 끝 — 세계 원복"; ./world.sh $V
