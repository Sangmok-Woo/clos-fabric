#!/usr/bin/env bash
# 실험 NN — 무엇을 보려는지 한두 줄.
#   Phase a  ...
#   Phase b  ...
# 캡처 지점: 노드:인터페이스 — 왜 거기인가
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=128                      # 헤더 흐름만 보면 충분하면 짧게 (pcap 을 저장소에 올린다)
ST=$HERE/state; rm -rf "$CAPDIR" "$ST"; mkdir -p "$CAPDIR" "$ST"
exec > >(tee "$CAPDIR/run-output.txt") 2>&1

# 바꿀 값의 원래 값을 state/ 에 적어 둔다 (restore.sh 가 되돌릴 때 쓴다)

say "기준값"

say "장애 주입"
cap_start a-node-ethN node ethN tcp port 80 or icmp
cap_wait 1
# 장애 넣기 → 트래픽 → 관찰
cap_stop

say "원복"
