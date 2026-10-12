#!/bin/bash
# 1~6 단계를 순서대로. 각 단계는 끝에서 스스로 원복한다. 캡처는 capture/ 로.
cd "$(dirname "$0")"; . ./lib.sh
docker ps --format '{{.Names}}' | grep -q clab-bgp-r100 || { echo "랩이 없다. ./up.sh 먼저."; exit 1; }
wait_up 60 >/dev/null
for n in 1 2 3 4 5 6; do bash stages/stage${n}-*.sh; done
echo; echo "== 전부 끝. 결과는 capture/stage*.txt, 캡처는 capture/*.pcap =="
