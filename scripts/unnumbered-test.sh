#!/usr/bin/env bash
# spine1↔leaf1 한 링크만 BGP unnumbered로 바꿔본다.
#   기존: neighbor 10.1.1.1 peer-group FABRIC       ... 링크 IP를 계산해서 지정
#   변경: neighbor eth1 interface peer-group FABRIC ... 인터페이스 이름만 지정
# 세션은 IPv6 link-local(fe80::) 위에 붙고, IPv4 경로의 넥스트홉도 fe80이 된다(RFC 5549).
# 링크 IP(/31)를 아예 지워도 동작하는 것까지 확인한 뒤, 원래대로 되돌린다.
# (configs/*.conf 는 읽기 전용 마운트라, 이 스크립트는 실행 중인 설정만 건드린다)
set -u
vs() { docker exec clab-clos-spine1 vtysh "$@" 2>/dev/null; }
vl() { docker exec clab-clos-leaf1  vtysh "$@" 2>/dev/null; }

echo "=== 0) 지금 상태 ==="
echo "-- spine1 eth1의 link-local 주소 (이게 있어야 unnumbered가 된다) --"
ll=$(docker exec clab-clos-spine1 ip -6 addr show dev eth1 | grep fe80)
if [ -z "$ll" ]; then
  echo "  없음 — 컨테이너에서 IPv6가 꺼져 있다. 여기서 중단."
  exit 1
fi
echo "$ll" | sed 's/^/  /'
echo "-- spine1이 보는 leaf1 서버망 경로 (지금은 IPv4 넥스트홉) --"
vs -c "show ip route 172.16.11.0/24" | grep -E "via" | sed 's/^/  /'

echo
echo "=== 1) 링크 IP(/31)를 지우고, IP 이웃을 인터페이스 이웃으로 바꾼다 ==="
echo "  (IP를 먼저 지워야 한다. IPv4가 남아 있으면 FRR이 세션을 IPv4로 붙여서 fe80이 안 보인다)"
vs -c "conf t" \
   -c "interface eth1" -c "no ip address 10.1.1.0/31" -c "exit" \
   -c "router bgp 65001" \
   -c "no neighbor 10.1.1.1" \
   -c "neighbor eth1 interface peer-group FABRIC" \
   -c "neighbor eth1 description leaf1" >/dev/null
vl -c "conf t" \
   -c "interface eth1" -c "no ip address 10.1.1.1/31" -c "exit" \
   -c "router bgp 65011" \
   -c "no neighbor 10.1.1.0" \
   -c "neighbor eth1 interface peer-group FABRIC" \
   -c "neighbor eth1 description spine1" >/dev/null
echo "  바꿨다. 세션이 붙기를 기다린다..."
ok=""
for i in $(seq 1 12); do
  st=$(vs -c "show ip bgp neighbors eth1 json" | grep -o '"bgpState":"Established"')
  if [ -n "$st" ]; then echo "  $((i*5))초: Established"; ok=1; break; fi
  echo "  $((i*5))초: 아직..."
  sleep 5
done
[ -z "$ok" ] && { echo "  60초가 지나도 안 붙었다. 아래 원복 단계만 직접 실행할 것."; }
sleep 5

echo
echo "=== 2) 세션이 어디 위에 붙었나 ==="
echo "-- Local/Foreign host가 fe80이면 link-local 위의 세션, Extended nexthop은 RFC 5549 협상 --"
vs -c "show ip bgp neighbors eth1" | grep -E "Extended nexthop|Local host|Foreign host" | sed 's/^/  /'

echo
echo "=== 3) 확인 ==="
echo "-- spine1 세션 목록 (이웃이 IP가 아니라 leaf1(eth1)로 보인다) --"
vs -c "show ip bgp summary" | grep -E "Neighbor|eth1|10\.1\.1\." | sed 's/^/  /'
echo
echo "-- spine1이 보는 leaf1 서버망: 넥스트홉이 fe80(link-local) --"
vs -c "show ip route 172.16.11.0/24" | sed 's/^/  /'
echo
echo "-- 커널 라우팅 테이블에도 그대로 들어간다 (via inet6 fe80::...) --"
docker exec clab-clos-spine1 ip route show 172.16.11.0/24 | sed 's/^/  /'
echo
echo "-- leaf1이 보는 h4 서버망: fe80(spine1) + 10.1.2.0(spine2) ECMP 혼용 --"
docker exec clab-clos-leaf1 ip route show 172.16.14.0/24 | sed 's/^/  /'
echo
echo "-- 서버 통신 (h1 -> h4) --"
docker exec clab-clos-h1 ping -c 2 -W 2 172.16.14.10 | tail -2

echo
echo "=== 4) 원래대로 되돌리기 ==="
vs -c "conf t" \
   -c "interface eth1" -c "ip address 10.1.1.0/31" -c "exit" \
   -c "router bgp 65001" \
   -c "no neighbor eth1 interface" \
   -c "neighbor 10.1.1.1 peer-group FABRIC" -c "neighbor 10.1.1.1 description leaf1" >/dev/null
vl -c "conf t" \
   -c "interface eth1" -c "ip address 10.1.1.1/31" -c "exit" \
   -c "router bgp 65011" \
   -c "no neighbor eth1 interface" \
   -c "neighbor 10.1.1.0 peer-group FABRIC" -c "neighbor 10.1.1.0 description spine1" >/dev/null
for i in $(seq 1 12); do
  c=$(vs -c 'show ip bgp summary json' | grep -o '"state":"Established"' | wc -l)
  echo "  $((i*5))초: established $c / 4"
  [ "$c" = "4" ] && break
  sleep 5
done
echo "-- 되돌린 뒤 서버 통신 (h1 -> h4) --"
docker exec clab-clos-h1 ping -c 2 -W 2 172.16.14.10 | tail -2
