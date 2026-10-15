#!/bin/bash
# run.sh 가 중간에 멈췄을 때 되돌리기 (전부 랩 컨테이너 안의 값). 랩 내리기는 containerlab destroy -t topology.yml --cleanup
HERE=$(cd "$(dirname "$0")" && pwd)
d() { docker exec "clab-natlab-$1" "${@:2}"; }
for n in cli1 cli2; do d $n pkill -f hog.py; done; d nat pkill tcpdump
if [ -f "$HERE/state/sysctl" ]; then while read -r k _ v; do d nat sysctl -qw "$k=$v"; done < "$HERE/state/sysctl"; fi
d nat nft flush ruleset; d cli1 nft flush ruleset
d nat ip addr del 10.9.100.2/24 dev eth3 2>/dev/null; d nat ip addr del 10.9.100.3/24 dev eth3 2>/dev/null
d nat conntrack -F >/dev/null 2>&1
echo "nat: $(d nat sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait net.netfilter.nf_conntrack_tcp_timeout_established net.netfilter.nf_conntrack_udp_timeout | tr '\n' ' ')"
