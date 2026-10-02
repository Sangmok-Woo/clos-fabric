#!/usr/bin/env bash
# L2 루프 + 브로드캐스트 스톰. leaf3 의 VXLAN 브리지(br10010)에 veth 한 쌍의 양 끝(lpA, lpB)을
# 둘 다 꽂는다 = 케이블 하나로 스위치 포트 두 개를 이어버린 실수. 브리지는 STP 가 꺼져 있다.
# 브로드캐스트 하나가 lpA → lpB → lpA … 를 영원히 돈다 (L2 프레임에는 TTL 이 없다).
# WSL 전체가 멈추지 않도록 루프 양쪽에 속도 제한(tbf 20Mbit)을 건다. 진짜 스톰은 이 제한이 없다.
#
# 캡처 지점:
#   leaf3:lpA      루프 자체 — 같은 프레임이 계속 돈다
#   v1:eth1        다른 랙의 서버 — VXLAN 을 타고 스톰이 번진다
#   leaf3:any BGP  EVPN — 루프 때문에 MAC 이 옮겨 다니는 것을 컨트롤플레인이 광고한다
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=160
rm -rf "$CAPDIR"; mkdir -p "$CAPDIR"
V1MAC=$(dx v1 cat /sys/class/net/eth1/address); V3MAC=$(dx v3 cat /sys/class/net/eth1/address)
fdb() { dx leaf3 bridge fdb show br br10010 | grep -E "$V1MAC|$V3MAC" | grep -v permanent | awk '{print "    "$1, "→", $3}' | sort -u; }
evpn() { dx leaf1 vtysh -c "show evpn mac vni 10010" | grep -E "$V3MAC" | sed 's/^/    leaf1: /'; }
rx() { dx "$1" cat /sys/class/net/eth1/statistics/rx_packets; }

say "기준값"
echo "  v1→v3 ping: $(dx v1 ping -c 5 -i 0.2 -q 10.10.10.33 | grep -o '[0-9]*% packet loss')"
echo "  leaf3 의 MAC 표 (v1, v3):"; fdb
echo "  EVPN 이 본 v3 MAC:"; evpn

say "루프 만들기 — leaf3 br10010 에 lpA/lpB"
# 포트가 올라오는 순간 자기 IPv6 멀티캐스트(NS, MLD)를 내보내 그것만으로 스톰이 시작된다(첫 실행에서 확인).
# 원인과 결과를 분리해 보려고 루프 포트의 IPv6 를 끈다. 진짜 현장에서는 이것만으로도 터진다.
dx leaf3 sh -c 'ip link add lpA type veth peer name lpB
  for p in lpA lpB; do sysctl -qw net.ipv6.conf.$p.disable_ipv6=1; ip link set $p master br10010; done
  ip link set lpA up; ip link set lpB up'
for p in lpA lpB; do nsx leaf3 tc qdisc add dev $p root tbf rate 20mbit burst 32k latency 50ms; done
cap_start leaf3-loop leaf3 lpA
cap_start v1-eth1    v1    eth1
SNAP=0 cap_start leaf3-bgp leaf3 any tcp port 179
cap_wait 1

b0=$(rx v1); sleep 2
echo "  루프만 만든 상태 2초 동안 v1 이 받은 패킷: $(( $(rx v1) - b0 ))개"

say "브로드캐스트 하나 (v3 가 없는 주소 10.10.10.99 를 ARP 로 묻는다)"
b1=$(rx v1)
dx v3 arping -c 1 -I eth1 10.10.10.99 >/dev/null 2>&1
sleep 3
echo "  3초 동안 v1 이 받은 패킷: $(( $(rx v1) - b1 ))개 (평소 0에 가깝다)"
echo "  leaf3 의 MAC 표:"; fdb
echo "  v1→v3 ping (스톰 중): $(dx v1 ping -c 10 -i 0.2 -q -W 1 10.10.10.33 | grep -o '[0-9]*% packet loss')"
echo "  EVPN 이 본 v3 MAC:"; evpn
sleep 2

say "루프 제거"
dx leaf3 ip link del lpA
sleep 3
cap_stop
# 스톰 캡처는 수십만 패킷이라 앞부분 3000개만 남긴다 (시작 순간이 핵심)
for f in leaf3-loop v1-eth1; do tcpdump -r "$CAPDIR/$f.pcap" -c 3000 -w "$CAPDIR/$f.t" 2>/dev/null && mv "$CAPDIR/$f.t" "$CAPDIR/$f.pcap"; done
cp "$CAPDIR"/*.pcap "$WINROOT/$(basename "$HERE")/capture/" 2>/dev/null
echo "  leaf3 의 MAC 표:"; fdb
echo "  v1→v3 ping (복구 후): $(dx v1 ping -c 5 -i 0.2 -q 10.10.10.33 | grep -o '[0-9]*% packet loss')"
echo "  EVPN 이 본 v3 MAC:"; evpn
say "남은 흔적 — EVPN 중복 MAC 감지"
# 루프 안에서 v1 의 프레임이 leaf3 로 돌아 들어오면 leaf3 가 v1 MAC 을 자기 것으로 광고한다.
# leaf1 과 leaf3 가 번갈아 광고하며 MAC Mobility 순번이 오르고, FRR 이 중복으로 찍는다(기본: 180초에 5번 이동).
for n in leaf1 leaf3; do dx $n vtysh -c "show evpn mac vni 10010 duplicate" | grep aa: | sed "s/^/    $n 중복: /"; done
for n in leaf1 leaf3; do dx $n vtysh -c "clear evpn dup-addr vni all" >/dev/null; done
echo "  clear evpn dup-addr vni all 로 정리"

