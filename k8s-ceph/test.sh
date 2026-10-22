#!/usr/bin/env bash
# 스토리지망 설계 요구사항을 랩에서 하나씩 확인한다. 각 줄이 PASS면 그 요구사항이 동작으로 증명된 것
# 사용법: ./test.sh            (기본 점검 + 장애 시험)
#         ./test.sh quick      (기본 점검만)
set -u
N=clab-clos
PASS=0; FAIL=0
x() { docker exec "$N-$1" sh -c "$2" >/dev/null 2>&1; }
ok() { if x "$2" "$3"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
ng() { if x "$2" "$3"; then echo "FAIL  $1"; FAIL=$((FAIL+1)); else echo "PASS  $1"; PASS=$((PASS+1)); fi; }
est() { echo "[ \$(vtysh -c 'show bgp $1 summary json' | grep -c '\"state\":\"Established\"') -ge $2 ]"; }

echo "== 1. 언더레이·EVPN 세션"
for l in leaf1 leaf2 leaf3 leaf4; do ok "$l EVPN 세션 2개 (스파인 둘)" $l "$(est 'l2vpn evpn' 2)"; done
for s in spine1 spine2; do ok "$s EVPN 세션 4개 (리프 넷)" $s "$(est 'l2vpn evpn' 4)"; done
ok "베이스 서버 h1 → h4 (기존 랩 그대로 동작)" h1 "ping -c2 -W1 172.16.14.10"

echo "== 2. 오버레이 (랙을 넘는 같은 서브넷)"
ok "wrk1(leaf1) → wrk3(leaf3) K8S-NODE"              wrk1  "ping -c2 -W1 10.10.16.23"
ok "ceph3(leaf4) → ceph1(leaf2) Ceph public 점보 9000"  ceph3 "ping -c2 -W1 -M do -s 8972 10.10.20.31"
ok "ceph3(leaf4) → ceph1(leaf2) Ceph cluster 점보 9000" ceph3 "ping -c2 -W1 -M do -s 8972 10.10.24.31"
ok "wrk1 → ceph3 스토리지 NIC로 직접, 점보 9000"       wrk1  "ping -c2 -W1 -M do -s 8972 10.10.20.33 && ip route get 10.10.20.33 | grep -q eth2.120"
ng "K8S-NODE는 1500 (점보 불가)"                      wrk1  "ping -c1 -W1 -M do -s 1600 10.10.16.23"

echo "== 3. 분리 (VRF)"
ng "wrk1 → Ceph cluster(REPL VRF) 도달 불가"   wrk1 "ping -c1 -W1 10.10.24.31"
ng "wrk1 노드망 → Ceph public 라우팅 불가 (VRF 간 누설 없음)" wrk1 "ping -c1 -W1 -I eth1.110 10.10.20.31"
ng "베이스 서버 h1 → Ceph public 도달 불가"     h1   "ping -c1 -W1 10.10.20.31"
ng "베이스 서버 h1 → K8s 노드망 도달 불가"      h1   "ping -c1 -W1 10.10.16.21"

echo "== 4. K8s BGP 피어링 (VIP 광고, 경로 필터)"
for l in 1 2 3; do ok "leaf$l ← wrk$l BGP 세션" leaf$l "vtysh -c 'show bgp vrf PROD neighbors 10.10.16.2$l json' | grep -q '\"bgpState\":\"Established\"'"; done
ok "leaf1이 VIP를 두 랙(leaf2·leaf3) 경유로 나눠 받음 (ECMP)" leaf1 "[ \$(ip route show vrf PROD 10.10.32.10 | grep -c nexthop) -ge 2 ]"
ok "wrk1 → VIP 10.10.32.10 도달"               wrk1 "ping -c2 -W1 10.10.32.10"
docker exec $N-wrk1 vtysh -c "conf t" -c "ip route 8.8.8.0/24 Null0" -c "router bgp 65200" \
  -c "address-family ipv4 unicast" -c "network 8.8.8.0/24" >/dev/null 2>&1
sleep 4
ng "노드가 엉뚱한 대역(8.8.8.0/24) 광고 → 리프가 거부" leaf1 "ip route show vrf PROD | grep -q 8.8.8.0"
docker exec $N-wrk1 vtysh -c "conf t" -c "router bgp 65200" -c "address-family ipv4 unicast" \
  -c "no network 8.8.8.0/24" -c "exit" -c "exit" -c "no ip route 8.8.8.0/24 Null0" >/dev/null 2>&1

if [ "${1:-}" = "quick" ]; then echo; echo "결과: PASS $PASS / FAIL $FAIL"; exit $FAIL; fi

echo "== 5. 장애 시험"
loss() {  # $1 장비 $2 목적지 $3 장애 장비 $4 장애 명령 $5 복구 명령
  docker exec $N-$1 sh -c "ping -i 0.05 -c 200 -W1 $2 > /tmp/p.txt" &
  P=$!; sleep 2
  docker exec $N-$3 sh -c "$4"
  wait $P
  docker exec $N-$3 sh -c "$5"
  docker exec $N-$1 sh -c "grep -o '[0-9]* received' /tmp/p.txt | cut -d' ' -f1"
}
r=$(loss ceph3 10.10.24.31 spine1 "ip link set eth2 down; ip link set eth4 down" "ip link set eth2 up; ip link set eth4 up")
echo "      복제 중 spine1의 leaf2·leaf4 링크 끊김 (ceph3 → ceph1 cluster): 200개 중 ${r}개 수신"
[ "$r" -ge 180 ] && { echo "PASS  스파인 경로 장애에도 Ceph 복제 유지"; PASS=$((PASS+1)); } || { echo "FAIL  스파인 경로 장애"; FAIL=$((FAIL+1)); }
sleep 10
docker exec $N-wrk2 vtysh -c "conf t" -c "router bgp 65200" -c "address-family ipv4 unicast" -c "no network 10.10.32.10/32" >/dev/null
sleep 4
ok "VIP 노드 1대(wrk2) 빠짐 → leaf1 경로가 wrk3 하나로 줄어듦" leaf1 "[ \$(ip route show vrf PROD 10.10.32.10 | grep -c nexthop) -eq 0 ] && ip route show vrf PROD 10.10.32.10 | grep -q 10.255.1.3"
ok "VIP 노드 1대(wrk2) 빠져도 VIP 도달"         wrk1 "ping -c2 -W1 10.10.32.10"
docker exec $N-wrk2 vtysh -c "conf t" -c "router bgp 65200" -c "address-family ipv4 unicast" -c "network 10.10.32.10/32" >/dev/null

echo; echo "결과: PASS $PASS / FAIL $FAIL"
exit $FAIL
