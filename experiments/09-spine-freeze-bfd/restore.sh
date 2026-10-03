#!/usr/bin/env bash
# run.sh 가 중간에 멈췄을 때 되돌리기 — 얼린 스파인을 풀고, 포워딩을 켜고, BFD 를 해제한다
. "$(dirname "$0")/../_tools/lab.sh"
for s in spine1 spine2; do
  docker unpause "$(c $s)" >/dev/null 2>&1
  nsx $s sysctl -qw net.ipv4.ip_forward=1
done
"$(cd "$HERE/../.." && pwd)/scripts/bfd-apply.sh" off >/dev/null
pkill -f "$CAPDIR" 2>/dev/null; dx h1 pkill ping 2>/dev/null
sleep 15; dx leaf1 vtysh -c "show ip bgp summary" | grep -E '^spine'
