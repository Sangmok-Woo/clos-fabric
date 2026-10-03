#!/usr/bin/env bash
# 캡처를 파일이 아니라 표준출력으로 흘려보낸다. 윈도우 Wireshark 에 파이프로 꽂는 용도.
# stdout 에는 pcap 바이트만 나가야 하므로, 안내문은 전부 stderr 로 보낸다.
#
# 사용법: ./scripts/stream.sh [노드] [인터페이스] [BPF필터]
# 예:     ./scripts/stream.sh leaf1 any 'udp port 4789'
set -eu
NODE=${1:-leaf1}
IFACE=${2:-any}
FILTER=${3:-udp port 4789}
PID=$(docker inspect -f '{{.State.Pid}}' "clab-clos-$NODE")
echo "[stream] $NODE:$IFACE  filter=$FILTER" >&2
exec nsenter -t "$PID" -n tcpdump -i "$IFACE" -s 0 -U -w - $FILTER 2>/dev/null
