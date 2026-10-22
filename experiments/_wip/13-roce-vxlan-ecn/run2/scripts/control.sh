#!/usr/bin/env bash
# 대조군 — 병목을 디캡 이후 구간(leaf3:eth6 → g3)으로 옮기고, 장애1(디캡 CE 누락)을 그대로 켠다.
# 표시가 안쪽 헤더에 바로 찍히므로 장애1 이 아무 영향을 주지 못해야 한다.
#   control.sh on <tcp|roce> | off      (멱등)
. "$(dirname "$0")/common.sh"
D=$(dirname "$0")
case ${1:-} in
  on)  "$D/bottleneck.sh" leaf ${2:-tcp}; "$D/inject-decap.sh" on ;;
  off) "$D/inject-decap.sh" off; "$D/bottleneck.sh" off ;;
  *) echo "on <tcp|roce> | off"; exit 1 ;;
esac
