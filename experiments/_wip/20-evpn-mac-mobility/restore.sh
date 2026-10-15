#!/usr/bin/env bash
# run.sh 가 만든 VM 자리(netns vmA·vmB, leaf1·leaf2 eth7)와 freeze 설정을 걷는다 (멱등)
. "$(dirname "$0")/../16-roce-vxlan-ecn/run2/scripts/common.sh"
H=$(cd "$(dirname "$0")" && pwd)
pkill -f 'garp.py m[AB]' 2>/dev/null; pkill -INT -f 'ping -I vr3 -i 0.01' 2>/dev/null
for n in 1 2; do
  dx leaf$n vtysh -c "conf t" -c "router bgp 6501$n" -c "address-family l2vpn evpn" -c "no dup-addr-detection freeze 30" >/dev/null 2>&1
  dx leaf$n vtysh -c "clear evpn dup-addr vni 10010 all" >/dev/null 2>&1
  dx leaf$n ip link del eth7 2>/dev/null
done
rm -f "$H/state/freeze"
for v in A B; do ip netns del vm$v 2>/dev/null; done
echo "남은 netns: $(ip netns list | grep -c '^vm[AB]')  leaf1 eth7: $(dx leaf1 ip link show eth7 >/dev/null 2>&1 && echo 있음 || echo 없음)  leaf2 dup-addr 설정: $(dx leaf2 vtysh -c 'show running-config' | grep -c 'dup-addr-detection freeze')"
