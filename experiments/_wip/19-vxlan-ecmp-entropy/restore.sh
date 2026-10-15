#!/usr/bin/env bash
# run.sh 가 바꾼 것을 되돌린다 (멱등): leaf1 해시 정책·필드, 업링크 큐, vxlan srcport, 16 장 2회차이 내려 둔 spine2:eth3
. "$(dirname "$0")/../16-roce-vxlan-ecn/run2/scripts/common.sh"
H=$(cd "$(dirname "$0")" && pwd)
pkill -9 -f 'ib_write_bw -d rxe_x' 2>/dev/null; pkill -9 -f 'iperf3 .*55(01|11|12)' 2>/dev/null
for p in $(pgrep -f "tcpdump .*19-vxlan-ecmp-entropy"); do kill $p; done
for d in eth1 eth2; do nsx leaf1 tc qdisc del dev $d root 2>/dev/null; done
dx leaf1 ip link set vni$VNI type vxlan srcport 0 0 2>/dev/null
vx_tos 0
[ -f "$H/state/policy" ] && { dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_policy=$(cat "$H/state/policy"); rm "$H/state/policy"; }
[ -f "$H/state/fields" ] && { dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_fields=$(cat "$H/state/fields"); rm "$H/state/fields"; }
if [ -f "$H/state/spine2-raised" ]; then nsx spine2 ip link set eth3 down; rm "$H/state/spine2-raised"; fi
echo "leaf1 해시 정책 $(dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_policy), fields $(dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_fields), vxlan $(dx leaf1 ip -d link show vni$VNI | grep -o 'srcport [0-9]* [0-9]*'), spine2 eth3 $(dx spine2 cat /sys/class/net/eth3/operstate)"
