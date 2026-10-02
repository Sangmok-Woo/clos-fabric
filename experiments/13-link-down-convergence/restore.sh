#!/usr/bin/env bash
# run.sh 가 중간에 멈췄을 때 되돌리기 — 내린 링크를 올리고 캡처·모니터를 끈다
. "$(dirname "$0")/../_tools/lab.sh"
for i in eth1 eth2; do dx leaf1 ip link set "$i" up; done
pkill -f "$CAPDIR" 2>/dev/null; pkill -f "ip monitor route" 2>/dev/null
dx h1 pkill ping 2>/dev/null
sleep 10; dx leaf1 vtysh -c "show ip bgp summary" | grep -E '^spine'
