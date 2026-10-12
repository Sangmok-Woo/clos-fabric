#!/bin/bash
# 세계 여론 지도: 모든 라우터의 <프리픽스> best 경로를 한 표로.  ./world.sh [프리픽스...]
# 프리픽스 대신 주소를 주면 그 주소에 가장 길게 일치하는 경로를 보여 준다 (FIB 가 실제로 따르는 것)
. "$(dirname "$0")/lib.sh"
[ $# -eq 0 ] && set -- $VICTIM
for p in "$@"; do
  echo "[$p]"
  printf '%-7s%-19s%-14s%-5s%-7s%-9s%s\n' node prefix next-hop LP origin rpki as-path
  for r in $ROUTERS; do vt $r "show bgp ipv4 unicast $p json" | python3 "$HERE/world.py" $r; done
  echo
done
