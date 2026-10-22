#!/usr/bin/env bash
# 윈도우 원본 → WSL 실행 사본. WSL root 로 실행. 결과(data/·capture/)는 반대로 되가져온다: sync.sh back
S=/mnt/c/Users/wsm02/Desktop/Claude/clos-fabric/experiments/_wip/14-roce-vxlan-ecn/run2
D=/root/labs/clos-fabric/experiments/_wip/14-roce-vxlan-ecn/run2
if [ "${1:-}" = back ]; then
  mkdir -p "$S/data" "$S/capture"
  cp -r "$D"/data/. "$S/data/"; [ -d "$D/capture" ] && cp -r "$D"/capture/. "$S/capture/"
  echo "back OK → $S"; exit 0
fi
mkdir -p "$D/scripts"
cp "$S"/sync.sh "$D"/; cp "$S"/scripts/* "$D"/scripts/
sed -i 's/\r$//' "$D"/sync.sh "$D"/scripts/*
chmod +x "$D"/sync.sh "$D"/scripts/*.sh "$D"/scripts/*.py 2>/dev/null
for f in "$D"/scripts/*.sh; do bash -n "$f" || exit 1; done
# 공통 도구(_tools/lab.sh)도 원본과 맞춘다
cp /mnt/c/Users/wsm02/Desktop/Claude/clos-fabric/experiments/_tools/lab.sh /root/labs/clos-fabric/experiments/_tools/lab.sh
sed -i 's/\r$//' /root/labs/clos-fabric/experiments/_tools/lab.sh
echo "sync OK → $D"
