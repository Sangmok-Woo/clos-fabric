#!/usr/bin/env bash
# setup.sh·run.sh·run-r8.sh 가 바꾼 것을 되돌린다 (커널 모듈은 남겨 둔다 — 내리려면 rmmod rdma_rxe crc32_generic)
# 사용: restore.sh       전부 (g1~g4·rxe 까지)
#       restore.sh r8    R8 이 깐 큐·도구만 (g1~g4·rxe 는 남긴다)
. "$(dirname "$0")/../_tools/lab.sh"

# ---- R8: ECN·DCQCN·PFC 큐와 흉내 도구 ----
pkill -TERM -f '12-roce/tools/(dcqcn|pfc).py' 2>/dev/null; sleep 1
pkill -9 -f '12-roce/tools/(dcqcn|pfc).py' 2>/dev/null
pkill -9 -f 'ib_(write|send|read)_(bw|lat)' 2>/dev/null; pkill -9 -f rping 2>/dev/null
for p in $(pgrep -f "tcpdump .*12-roce"); do kill $p; done
nsx leaf3 tc qdisc del dev eth5 root 2>/dev/null
for s in 1 2; do
  nsx spine$s tc qdisc del dev eth3 root 2>/dev/null
  for n in 1 2 4; do nsx leaf$n tc qdisc del dev eth$s root 2>/dev/null; done
done
for n in 1 2 4; do
  nsx h$n tc qdisc del dev eth1 root 2>/dev/null
  tc qdisc del dev g$n root 2>/dev/null
done
if [ "${1:-}" = r8 ]; then
  echo "남은 qdisc (noqueue/noop 이 아닌 것):"
  for d in g1 g2 g4; do tc qdisc show dev $d 2>/dev/null | grep -vE 'noqueue|noop' | sed "s/^/  $d: /"; done
  nsx leaf3 tc qdisc show dev eth5 | grep -vE 'noqueue|noop' | sed 's/^/  leaf3 eth5: /'
  exit 0
fi

# ---- R1~R7 과 setup.sh ----
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
