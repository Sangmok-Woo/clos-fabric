#!/usr/bin/env bash
# setup.sh·run.sh 가 바꾼 것을 되돌린다 (커널 모듈은 남겨 둔다 — 내리려면 rmmod rdma_rxe crc32_generic)
. "$(dirname "$0")/../_tools/lab.sh"
pkill -9 -f 'ib_(write|send|read)_(bw|lat)' 2>/dev/null; pkill -9 -f rping 2>/dev/null
for p in $(pgrep -f "tcpdump .*12-roce"); do kill $p; done
nsx leaf3 tc qdisc del dev eth5 root 2>/dev/null
[ -f "$HERE/state/hash" ] && nsx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_policy="$(cat "$HERE/state/hash")"
for n in 1 2 3 4; do
  docker exec rtool rdma link del rxe_g$n 2>/dev/null
  dx leaf$n vtysh -c "conf t" -c "router bgp 6501$n" -c "address-family ipv4 unicast" -c "no network 172.16.2$n.0/24" \
     -c "exit" -c "exit" -c "interface eth5" -c "no ip address 172.16.2$n.1/24" >/dev/null 2>&1
  ip link del g$n 2>/dev/null; ip link del vg$n 2>/dev/null
done
ip rule show | grep -q '^0:.*lookup local' || ip rule add pref 0 table local
ip rule del pref 32765 table local 2>/dev/null
ip rule del pref 1000 l3mdev 2>/dev/null   # VRF 를 처음 만들 때 커널이 넣은 규칙
sysctl -qw net.ipv4.udp_l3mdev_accept=0 net.ipv4.tcp_l3mdev_accept=0
docker rm -f rtool >/dev/null 2>&1
ip rule show | head -3
dx leaf1 ip route | grep -c 172.16.2 | sed 's/^/leaf1 에 남은 172.16.2x 경로: /'
