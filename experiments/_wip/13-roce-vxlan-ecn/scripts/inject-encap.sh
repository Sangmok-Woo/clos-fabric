#!/usr/bin/env bash
# 장애 2 — 캡슐화 때 ECT 누락. 사용: inject-encap.sh on | off | show
# 송신 리프(leaf1·leaf2·leaf4) 업링크(eth1·eth2) egress 에서, VXLAN 바깥 IP 헤더의 ECN 2비트를 Not-ECT(00)로 지운다.
# 안쪽 헤더는 ECT 그대로다. 병목 RED 는 바깥 헤더만 보므로 마킹 대신 드랍하게 된다.
. "$(dirname "$0")/common.sh"
case "${1:-show}" in
  on)
    for L in leaf1 leaf2 leaf4; do for d in eth1 eth2; do
      nsx $L tc qdisc replace dev $d clsact
      nsx $L tc filter del dev $d egress pref 16 2>/dev/null
      nsx $L tc filter add dev $d egress pref 16 protocol ip flower ip_proto udp dst_port 4789 \
        action pedit ex munge ip tos set 0x00 retain 0x03 pipe action csum ip
    done; done ;;
  off)
    for L in leaf1 leaf2 leaf4; do for d in eth1 eth2; do nsx $L tc qdisc del dev $d clsact 2>/dev/null; done; done; true ;;
esac
for L in leaf1 leaf2 leaf4; do
  n=$(nsx $L tc -s filter show dev eth1 egress 2>/dev/null | awk '/action order 1: *pedit/{f=1} f&&/Sent/{print $4; exit}')
  echo "  $L eth1 egress ECN→00 필터: ${n:-없음}${n:+ 패킷}"
done
