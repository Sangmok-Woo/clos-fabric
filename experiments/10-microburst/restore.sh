#!/usr/bin/env bash
# run.sh 가 중간에 멈췄을 때 되돌리기
. "$(dirname "$0")/../_tools/lab.sh"
nsx leaf3 tc qdisc del dev eth3 root 2>/dev/null
dx h3 pkill iperf3 2>/dev/null
pkill -f "$CAPDIR" 2>/dev/null
nsx leaf3 tc qdisc show dev eth3
