#!/usr/bin/env bash
# RoCE 서버 4대(g1~g4)를 패브릭에 붙인다. 먼저 커널에 rdma_rxe·crc32_generic 모듈이 올라와 있어야 한다 (README 0단계).
#
# 6.6 커널의 rxe 는 netns 를 모른다 — 경로 찾기(ip_route_output_key(&init_net))와 수신 소켓(UDP 4791)이
# 기본 네임스페이스에 고정돼 있다. 그래서 서버를 컨테이너가 아니라 WSL 기본 네임스페이스의 VRF 로 만든다.
#   vgN (VRF, 표 10N)  주소 172.16.2N.10/32   ← rxe_gN 이 여기에 붙는다 (GID = 이 주소)
#    └ gN (veth)       주소 172.16.2N.11/24   ↔  leafN:eth5 172.16.2N.1/24, BGP 로 광고
# rxe 를 veth(gN)가 아니라 VRF 장치(vgN)에 붙이는 이유: VRF 포트로 들어온 패킷은 커널이 수신 장치를
# VRF 장치로 바꿔 넘기므로, gN 에 붙은 rxe 는 자기 패킷을 못 알아보고 버린다.
set -e
. "$(dirname "$0")/../_tools/lab.sh"
mkdir -p "$HERE/state"
T() { docker exec rtool "$@"; }

# 도구 상자: rdma-core·perftest·iperf3 (Ubuntu 패키지). 기본 네임스페이스에서 돈다
docker image inspect rdma-tools >/dev/null 2>&1 || docker build -q --network host -t rdma-tools "$HERE/tools"
# WSL 이 재시작되면 멈춘 rtool 이 남아 이름이 겹친다 → 돌고 있지 않으면 지우고 새로
docker ps --format '{{.Names}}' | grep -qx rtool || { docker rm -f rtool >/dev/null 2>&1
  docker run -d --name rtool --network host --privileged -v /dev/infiniband:/dev/infiniband -v /tmp:/tmp rdma-tools sleep infinity >/dev/null; }

# VRF 로 가는 흐름이 local 표보다 VRF 표를 먼저 보게 한다 (안 그러면 g1→g3 이 패브릭을 안 타고 로컬로 꺾인다)
ip rule show | grep -q '^32765:.*lookup local' || { ip rule add pref 32765 table local; ip rule del pref 0 table local; }
sysctl -qw net.ipv4.udp_l3mdev_accept=1 net.ipv4.tcp_l3mdev_accept=1

for n in 1 2 3 4; do
  ip link show g$n >/dev/null 2>&1 && continue
  ip link add vg$n type vrf table 10$n; ip link set vg$n up
  ip link add g$n type veth peer name eth5 netns "$(pid leaf$n)"
  ip link set g$n master vg$n; ip link set g$n mtu 9500 up
  ip addr add 172.16.2$n.11/24 dev g$n
  ip addr add 172.16.2$n.10/32 dev vg$n
  ip route add default via 172.16.2$n.1 vrf vg$n
  dx leaf$n ip link set eth5 mtu 9500 up
  dx leaf$n vtysh -c "conf t" -c "interface eth5" -c "ip address 172.16.2$n.1/24" \
     -c "router bgp 6501$n" -c "address-family ipv4 unicast" -c "network 172.16.2$n.0/24" >/dev/null
  T rdma link add rxe_g$n type rxe netdev vg$n
done
sleep 3
T rdma link | grep rxe_g
ping -I vg1 -c 2 -W 1 -q 172.16.23.10 2>/dev/null | tail -1
