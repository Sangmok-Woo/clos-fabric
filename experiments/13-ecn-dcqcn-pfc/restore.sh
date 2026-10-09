#!/usr/bin/env bash
# run.sh 가 바꾼 것을 되돌린다. 실험 12 의 g1~g4·rxe 장치는 남긴다 (그쪽은 12-roce/restore.sh)
. "$(dirname "$0")/../_tools/lab.sh"
pkill -TERM -f '13-ecn-dcqcn-pfc/tools/(dcqcn|pfc).py' 2>/dev/null; sleep 1
pkill -9 -f '13-ecn-dcqcn-pfc/tools/(dcqcn|pfc).py' 2>/dev/null
pkill -9 -f 'ib_write_bw' 2>/dev/null
for p in $(pgrep -f "tcpdump .*13-ecn-dcqcn-pfc"); do kill $p; done
nsx leaf3 tc qdisc del dev eth5 root 2>/dev/null
for s in 1 2; do
  nsx spine$s tc qdisc del dev eth3 root 2>/dev/null
  for n in 1 2 4; do nsx leaf$n tc qdisc del dev eth$s root 2>/dev/null; done
done
for n in 1 2 4; do
  nsx h$n tc qdisc del dev eth1 root 2>/dev/null
  tc qdisc del dev g$n root 2>/dev/null
done
echo "남은 qdisc (noqueue/noop 이 아닌 것):"
for d in g1 g2 g4; do tc qdisc show dev $d 2>/dev/null | grep -vE 'noqueue|noop' | sed "s/^/  $d: /"; done
nsx leaf3 tc qdisc show dev eth5 | grep -vE 'noqueue|noop' | sed 's/^/  leaf3 eth5: /'
