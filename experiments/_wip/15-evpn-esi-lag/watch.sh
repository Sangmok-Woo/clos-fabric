#!/usr/bin/env bash
# 50ms 마다 세 군데 상태를 보고, 바뀔 때만 "시각 상태" 한 줄을 남긴다. watch.sh <출력> <멈춤파일>
#   leaf3 : hmh MAC 을 어느 VTEP(들)로 보내는가 (커널 FDB → nexthop 그룹)
#   hmh   : bond0 의 두 줄이 살아 있고 실제로 묶여(active aggregator) 있는가
#   leaf1·leaf2 : bond1 / eth5 protodown (uplink 추적이 걸었는지)
. "$(dirname "$0")/common.sh"
OUT=$1; STOP=$2
P3=$(pid leaf3); PM=$(pid hmh); P1=$(pid leaf1); P2=$(pid leaf2)


last=""
while [ ! -e "$STOP" ]; do
  s="leaf3→hmh=[$(l3 $P3)] hmh=[$(mh $PM)] leaf1=[$(pd $P1)] leaf2=[$(pd $P2)]"
  [ "$s" != "$last" ] && { echo "$(date +%s.%N | cut -c1-14) $s" >> "$OUT"; last=$s; }
  sleep 0.05
done
