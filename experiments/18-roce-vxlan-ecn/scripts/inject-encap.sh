#!/usr/bin/env bash
# 장애2 — 캡슐화 시 ECT 누락. 송신 리프(leaf1·2·4) 업링크(eth1·eth2) egress 에서 VXLAN 바깥 ECN 을 Not-ECT(00)로.
# 병목 스위치(spine1)는 Not-ECT 패킷에 표시 대신 드랍한다 → 손실 기반으로 떨어진다.
#   inject-encap.sh on | off | status      (멱등)
. "$(dirname "$0")/common.sh"
case ${1:-status} in
  on)  encap_fault_on ;;
  off) encap_fault_off ;;
esac
for n in $SENDERS; do
  echo "leaf$n eth1/eth2 egress pref 50: $(for d in eth1 eth2; do nsx leaf$n tc filter show dev $d egress pref 50 2>/dev/null | grep -q pedit && echo -n '켜짐 ' || echo -n '없음 '; done)"
done
