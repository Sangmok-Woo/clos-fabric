#!/usr/bin/env bash
# run.sh 가 중간에 멈췄을 때 되돌리기: 이 디렉터리에서 돌던 run.sh·캡처를 끄고, 멈춘 스파인을 풀고, 랩을 새로 띄운다
# (GR·BFD·링크·daemons 파일을 처음 상태로). 이 랩(clab-grlab-*)만 건드린다.
. "$(dirname "$0")/../../_tools/lab.sh"
c() { echo "clab-grlab-$1"; }
for p in $(pgrep -f 'run.sh'); do   # 명령줄이 ./run.sh 라 경로로는 못 찾는다 → 작업 디렉터리로 고른다
  [ "$(readlink /proc/$p/cwd 2>/dev/null)" = "$HERE" ] && [ "$p" != $$ ] && kill "$p"
done
[ -f "$CAPDIR/.pids" ] && xargs -r kill < "$CAPDIR/.pids" 2>/dev/null; rm -f "$CAPDIR/.pids"
for n in spine1 spine2; do
  [ "$(docker inspect -f '{{.State.Paused}}' "$(c $n)" 2>/dev/null)" = true ] && docker unpause "$(c $n)"
done
"$HERE/down.sh" && "$HERE/up.sh"
