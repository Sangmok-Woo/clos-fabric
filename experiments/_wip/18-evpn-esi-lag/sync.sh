#!/usr/bin/env bash
# 윈도우 원본 → WSL 실행 사본. back 이면 capture/ 를 되가져온다. WSL root 로 실행.
S=/mnt/c/Users/sangmok/Desktop/Claude/clos-fabric/experiments/_wip/18-evpn-esi-lag
D=/root/labs/clos-fabric/experiments/_wip/18-evpn-esi-lag
if [ "${1:-}" = back ]; then mkdir -p "$S/capture"; rsync -a --exclude '*.pcap' "$D"/capture/ "$S/capture/"; echo "back OK"; exit 0; fi
mkdir -p "$D"; cp "$S"/*.sh "$S"/*.py "$D"/ 2>/dev/null
for f in "$D"/*.sh "$D"/*.py; do tr -d '\r' < "$f" > "$f.t" && mv "$f.t" "$f"; done; chmod +x "$D"/*.sh "$D"/*.py
for f in "$D"/*.sh; do bash -n "$f" || exit 1; done; echo "sync OK → $D"
