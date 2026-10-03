#!/usr/bin/env bash
# run.sh 가 중간에 멈췄을 때 되돌리기
. "$(dirname "$0")/../_tools/lab.sh"
orig=$(cat "$HERE/state/hash.orig" 2>/dev/null || echo 0)
dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_policy="$orig"
dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_fields="$(cat "$HERE/state/fields.orig" 2>/dev/null || echo 7)"
for i in $(seq 101 108); do dx h1 ip addr del "172.16.11.$i/24" dev eth1 2>/dev/null; done
pkill -f "$CAPDIR" 2>/dev/null
echo "leaf1 해시 정책 $(dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_policy)"; dx h1 ip -4 addr show eth1 | grep inet
