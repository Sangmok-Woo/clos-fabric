#!/usr/bin/env bash
# run.sh 가 중간에 멈췄을 때 되돌린다. g1~g4·rxe 는 16 장 2회차 teardown.sh 가 걷는다
. "$(dirname "$0")/../16-roce-vxlan-ecn/run2/scripts/common.sh"
pkill -9 -f 'ib_write_(bw|lat) -d rxe_x' 2>/dev/null; pkill -9 -f 'iperf3 .*540[24]' 2>/dev/null
for p in $(pgrep -f "tcpdump .*18-vxlan-dscp-qos"); do kill $p; done
vx_tos 0
nsx spine1 tc qdisc del dev eth3 root 2>/dev/null
echo "spine1 eth3: $(nsx spine1 tc qdisc show dev eth3 | head -1)"
echo "leaf1 vni: $(dx leaf1 ip -d link show vni10010 | grep -o 'tos [^ ]*' || echo 'tos 기본(0)')"
