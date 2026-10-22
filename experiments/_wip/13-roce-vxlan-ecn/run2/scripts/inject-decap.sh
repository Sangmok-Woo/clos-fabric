#!/usr/bin/env bash
# 장애1 — 디캡 시 CE 누락. leaf3 업링크(eth1·eth2) ingress 에서 바깥 IP 의 CE(11)를 ECT(0)(10)로 되돌린다.
# DSCP 6비트는 pedit retain 0x03 으로 건드리지 않는다. "VTEP 이 CE 를 안쪽으로 옮기지 않은 것"과 같은 효과.
# (Step 1: 리눅스 vxlan 은 원래 옮긴다 → 이 장애는 인위적 재현이다)
#   inject-decap.sh on | off | status      (멱등)
. "$(dirname "$0")/common.sh"
case ${1:-status} in
  on)  decap_fault_on ;;
  off) decap_fault_off ;;
esac
for d in eth1 eth2; do
  echo "leaf3 $d ingress pref 50: $(nsx leaf3 tc filter show dev $d ingress pref 50 2>/dev/null | grep -q pedit && echo '장애1 켜짐' || echo '없음')"
done
