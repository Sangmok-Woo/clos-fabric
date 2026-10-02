#!/usr/bin/env bash
. "$(dirname "$0")/../_tools/lab.sh"
dx leaf3 ip link del lpA 2>/dev/null; pkill -f "$CAPDIR" 2>/dev/null
for n in leaf1 leaf3; do dx $n vtysh -c "clear evpn dup-addr vni all" >/dev/null; done
dx leaf3 bridge link show | grep -c lp || echo "루프 없음"
