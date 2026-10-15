#!/usr/bin/env bash
# setup.sh·inject-*.sh·control.sh 가 바꾼 것을 전부 되돌리고 패브릭 상태를 확인한다. 여러 번 돌려도 된다.
# 커널 모듈(rdma_rxe 등)은 남긴다.
. "$(dirname "$0")/common.sh"

say "장애·병목 해제"
"$EXP/scripts/inject-decap.sh" off >/dev/null
"$EXP/scripts/inject-encap.sh" off >/dev/null
bn_off $BN_SPINE; bn_off $BN_RXPORT
dx v3 pkill iperf3 2>/dev/null; true

say "트랙 A rxe 서버"
for n in 1 3; do
  docker exec rtool rdma link del rxe_e$n 2>/dev/null
  ip link del e$n 2>/dev/null; ip link del ve$n 2>/dev/null
done
ip rule show | grep -q '^0:.*lookup local' || ip rule add pref 0 table local
ip rule del pref 32765 table local 2>/dev/null
ip rule del pref 1000 l3mdev 2>/dev/null
sysctl -qw net.ipv4.udp_l3mdev_accept=0 net.ipv4.tcp_l3mdev_accept=0
docker rm -f rtool >/dev/null 2>&1; true

say "송신 서버 x2·x4 와 leaf2·leaf4 VNI"
docker rm -f "$(c x2)" "$(c x4)" >/dev/null 2>&1
for pair in "leaf2 65012" "leaf4 65014"; do
  set -- $pair
  dx $1 vtysh -c "conf t" -c "router bgp $2" -c "address-family l2vpn evpn" -c "no advertise-all-vni" >/dev/null
  dx $1 sh -c "ip link del $VX 2>/dev/null; ip link del $BR 2>/dev/null; ip link del eth4 2>/dev/null"; true
done

say "서버 설정 되돌리기"
for h in v1 v3; do
  nsx $h ip link set eth1 mtu 9500
  docker exec --privileged "$(c $h)" ethtool -K eth1 tso on gso on gro on >/dev/null 2>&1
  nsx $h sysctl -qw net.ipv4.tcp_ecn=2 net.ipv4.tcp_congestion_control=cubic
done
[ -f "$STATE/allowed_cc" ] && sysctl -qw net.ipv4.tcp_allowed_congestion_control="$(cat "$STATE/allowed_cc")" && rm -f "$STATE/allowed_cc"

say "경로 고정 해제 (spine2 eth3 up)"
nsx spine2 ip link set eth3 up
sleep 12

say "패브릭 확인"
for n in leaf1 leaf3; do echo "  $n BGP Established: $(dx $n vtysh -c 'show bgp summary' | grep -cE '^spine[12].* [0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9:]+ +[0-9]+')"; done
echo "  leaf1 EVPN 경로(Type-2/3): $(dx leaf1 vtysh -c 'show bgp l2vpn evpn route' | grep -cE '^ *\*>? *\[[23]\]')"
echo "  leaf1 → leaf3 VTEP 경로: $(dx leaf1 ip route show 10.255.1.3 | grep -c nexthop) 갈래"
echo "  v1 → v3 $(dx v1 ping -c 3 -W 1 -q 10.10.10.33 | grep -o '[0-9]*% packet loss')"
echo "  h1 → h3 $(dx h1 ping -c 3 -W 1 -q 172.16.13.10 | grep -o '[0-9]*% packet loss')"
for d in "spine1 eth3" "leaf3 eth1" "leaf1 eth1" "leaf3 eth4"; do set -- $d; echo "  $1 $2 qdisc: $(nsx $1 tc qdisc show dev $2 | awk '{print $2}' | sort -u | tr '\n' ' ')"; done
