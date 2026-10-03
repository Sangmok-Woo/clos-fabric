#!/usr/bin/env bash
# run.sh 가 중간에 멈췄을 때 되돌리기
. "$(dirname "$0")/../_tools/lab.sh"
pkill -f "$CAPDIR" 2>/dev/null
