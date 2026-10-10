#!/bin/bash
# 윈도우 원본 -> WSL 실행 사본 (CRLF 제거). WSL root 에서: bash /mnt/c/Users/wsm02/Desktop/Claude/clos-fabric/experiments/16-ecmp-fw-sync/sync.sh
SRC=/mnt/c/Users/wsm02/Desktop/Claude/clos-fabric/experiments/16-ecmp-fw-sync
DST=/root/labs/clos-fabric/experiments/16-ecmp-fw-sync
mkdir -p $DST && cp -a $SRC/. $DST/
find $DST -type f \( -name '*.yml' -o -name '*.nft' -o -name '*.sh' -o -name '*.conf' -o -name Dockerfile \) -exec sed -i 's/\r$//' {} +
chmod +x $DST/*.sh $DST/image/*.sh $DST/tools/*.sh
