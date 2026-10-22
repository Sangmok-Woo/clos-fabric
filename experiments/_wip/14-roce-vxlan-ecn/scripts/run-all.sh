#!/usr/bin/env bash
# 전체 순서. 사용: run-all.sh [반복=3] [초=60]
# 베이스 패브릭 + evpn-apply.sh 가 떠 있는 상태에서 시작한다. rxe(트랙 A)는 커널을 멈춘 적이 있어 맨 끝에 따로 돌린다.
. "$(dirname "$0")/common.sh"
REPS=${1:-3}; DUR=${2:-60}; S=$EXP/scripts
rm -f "$DATA"/summary.csv "$DATA"/{baseline,fault-decap,fault-encap,control-base,control-decap}-r*.csv

# 중간에 끊긴 실행이 남긴 장애·병목부터 걷는다
"$S/inject-decap.sh" off >/dev/null; "$S/inject-encap.sh" off >/dev/null; bn_off $BN_RXPORT
"$S/setup.sh"
"$S/q1-signal.sh" 8                                       # Step 1

"$S/measure.sh" baseline "$REPS" "$DUR"                   # Step 2
"$S/inject-decap.sh" on;  "$S/measure.sh" fault-decap "$REPS" "$DUR"; "$S/inject-decap.sh" off   # Step 3
"$S/inject-encap.sh" on;  "$S/measure.sh" fault-encap "$REPS" "$DUR"; "$S/inject-encap.sh" off   # Step 4
"$S/control.sh" on                                        # Step 5
"$S/measure.sh" control-base "$REPS" "$DUR"
"$S/inject-decap.sh" on;  "$S/measure.sh" control-decap "$REPS" "$DUR"; "$S/inject-decap.sh" off
"$S/control.sh" off
say "끝. 다음: rxe-track.sh (트랙 A), teardown.sh (Step 6)"
