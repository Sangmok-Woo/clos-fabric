#!/usr/bin/env bash
# 병목 위치·큐 바꾸기 (멱등)
#   bottleneck.sh spine <tcp|roce>   spine1:eth3 egress (VXLAN 구간, 바깥 헤더에 표시)  ← 기본
#   bottleneck.sh leaf  <tcp|roce>   leaf3:eth6 egress (디캡 이후, 안쪽 헤더에 표시)   ← 대조군
#   bottleneck.sh off
. "$(dirname "$0")/common.sh"
case ${1:-} in
  spine) bneck_off leaf3 eth6;  bneck_on spine1 eth3 ${2:-tcp} ;;
  leaf)  bneck_off spine1 eth3; bneck_on leaf3 eth6 ${2:-tcp} ;;
  off)   bneck_off spine1 eth3; bneck_off leaf3 eth6 ;;
  *) echo "spine|leaf|off [tcp|roce]"; exit 1 ;;
esac
echo "spine1 eth3: $(nsx spine1 tc qdisc show dev eth3 | grep -o 'red .*' | head -1)"
echo "leaf3  eth6: $(nsx leaf3 tc qdisc show dev eth6 | grep -o 'red .*' | head -1)"
