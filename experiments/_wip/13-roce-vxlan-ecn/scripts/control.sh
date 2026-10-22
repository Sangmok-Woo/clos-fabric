#!/usr/bin/env bash
# 대조군 — 병목을 디캡 뒤 구간(leaf3 → v3, eth4 egress)으로 옮긴다. 사용: control.sh on | off | show
# on : 스파인 병목을 걷고 leaf3 eth4 에 같은 큐(100Mbit + RED/ECN)를 건다. 마킹이 안쪽 헤더에 바로 찍힌다
# off: 원래대로 스파인 병목
. "$(dirname "$0")/common.sh"
case "${1:-show}" in
  on)  bn_off $BN_SPINE;  bn_on $BN_RXPORT ;;
  off) bn_off $BN_RXPORT; bn_on $BN_SPINE ;;
esac
for p in "$BN_SPINE" "$BN_RXPORT"; do
  set -- $p
  q=$(nsx $1 tc qdisc show dev $2 | grep -o 'qdisc red' || true)
  echo "  $1 $2: ${q:-병목 없음}"
done
