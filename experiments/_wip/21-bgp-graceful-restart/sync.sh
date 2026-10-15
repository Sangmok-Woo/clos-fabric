#!/usr/bin/env bash
# 윈도우 원본 → WSL 실행 사본, back 이면 capture/ 를 되가져온다. WSL root 로 실행.
S=/mnt/c/Users/wsm02/Desktop/Claude/clos-fabric/experiments/_wip/21-bgp-graceful-restart
D=/root/labs/clos-fabric/experiments/_wip/21-bgp-graceful-restart
if [ "${1:-}" = back ]; then mkdir -p "$S/capture"; cp -r "$D"/capture/. "$S/capture/"; echo "back OK"; exit 0; fi
mkdir -p "$D"; cp "$S"/*.sh "$S"/*.yml "$D"/; cp -r "$S"/configs "$D"/
sed -i 's/\r$//' "$D"/*.sh "$D"/*.yml "$D"/configs/docker-start "$D"/configs/daemons "$D"/configs/vtysh.conf "$D"/configs/*/frr.conf
chmod +x "$D"/*.sh "$D"/configs/docker-start
for f in "$D"/*.sh; do bash -n "$f" || exit 1; done; echo "sync OK → $D"
