#!/usr/bin/env bash
# run.sh 가 중간에 멈췄을 때 되돌리기
. "$(dirname "$0")/../_tools/lab.sh"
for n in mob tb1 tb3; do ip netns del $n 2>/dev/null; done
for l in leaf1 leaf3; do dx $l sh -c 'ip link del vni10020 2>/dev/null; ip link del br10020 2>/dev/null'; done
dx leaf1 ip addr del 10.10.10.201/24 dev br10010 2>/dev/null
dx leaf3 ip addr del 10.10.10.203/24 dev br10010 2>/dev/null
dx leaf1 bridge link set dev vni10010 neigh_suppress on
dx leaf3 vtysh -c "conf t" -c "router bgp 65013" -c "address-family l2vpn evpn" -c "advertise-all-vni" >/dev/null
dx h3 ip addr del 172.16.11.50/24 dev eth1 2>/dev/null
dx v3 ip link set eth1 up
[ -f "$HERE/state/hmtu" ] && while read -r h m; do dx $h ip link set eth1 mtu "$m"; done < "$HERE/state/hmtu"
for s in v3 h3; do dx $s pkill iperf3 2>/dev/null; done
for p in $(pgrep -f "tcpdump .*08-packet-life"); do kill $p; done
dx v1 ping -c 2 -W 1 -q 10.10.10.33 | tail -1
