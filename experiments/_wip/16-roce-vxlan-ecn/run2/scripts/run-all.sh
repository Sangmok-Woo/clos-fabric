#!/usr/bin/env bash
# Step 2~5 — 트랙 × 시나리오 × 반복. setup.sh 다음에 실행한다. 결과는 data/runs/<트랙>/<시나리오>-r<N>/
#   run-all.sh [트랙들] [반복] [초]      기본: "tcp dcqcn roce" 3 60
#   시나리오  base(병목 spine1) · decap(+장애1) · encap(+장애2) · control(병목 leaf3:eth6 + 장애1)
set -u
D=$(dirname "$0"); . "$D/common.sh"
TRACKS=${1:-tcp dcqcn roce}; REPS=${2:-3}; DUR=${3:-60}
exec > >(tee -a "$DATA/run-all.txt") 2>&1
date
for tr in $TRACKS; do
  q=tcp; [ $tr != tcp ] && q=roce
  for rep in $(seq $REPS); do
    for sc in base decap encap control; do
      say "$tr / $sc / r$rep"
      "$D/inject-decap.sh" off >/dev/null; "$D/inject-encap.sh" off >/dev/null
      case $sc in
        base)    "$D/bottleneck.sh" spine $q >/dev/null ;;
        decap)   "$D/bottleneck.sh" spine $q >/dev/null; "$D/inject-decap.sh" on >/dev/null ;;
        encap)   "$D/bottleneck.sh" spine $q >/dev/null; "$D/inject-encap.sh" on >/dev/null ;;
        control) "$D/control.sh" on $q >/dev/null ;;
      esac
      "$D/measure.sh" $tr "$DATA/runs/$tr/$sc-r$rep" $DUR
      "$D/inject-decap.sh" off >/dev/null; "$D/inject-encap.sh" off >/dev/null; "$D/bottleneck.sh" off >/dev/null
      sleep 3
    done
  done
done
date
