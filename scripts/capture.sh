#!/usr/bin/env bash
# 랩 안의 아무 지점이나 패킷 캡처. 컨테이너에는 tcpdump가 없어서
# 호스트 tcpdump를 nsenter로 그 컨테이너의 네트워크 안에 꽂아 쓴다.
#
# 사용법:
#   ./scripts/capture.sh <노드> <인터페이스> <초> [파일이름] [BPF필터...]
# 예:
#   ./scripts/capture.sh leaf1 eth2 10 vxlan  'udp port 4789'
#   ./scripts/capture.sh leaf1 eth2 20 bgp    'tcp port 179'
#   ./scripts/capture.sh spine2 eth1 10 spine 'udp port 4789'
#
# 주의: VXLAN 트래픽은 ECMP 해시 때문에 업링크 한쪽(eth1 또는 eth2)으로만 간다.
#       한쪽이 비어 있으면 반대쪽을 잡아볼 것.
set -eu
cd "$(dirname "$0")/.."
NODE=${1:?노드 이름 (leaf1, spine2, v1 ...)}
IFACE=${2:-eth1}
SECS=${3:-10}
NAME=${4:-$NODE-$IFACE}
shift 4 2>/dev/null || shift $# 
FILTER="${*:-}"

OUT_DIR=captures
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$NAME.pcap"

PID=$(docker inspect -f '{{.State.Pid}}' "clab-clos-$NODE")
echo "[$NODE:$IFACE] ${SECS}초 캡처${FILTER:+ (필터: $FILTER)} -> $OUT"
nsenter -t "$PID" -n tcpdump -i "$IFACE" -s 0 -w "$OUT" $FILTER 2>/dev/null &
TD=$!
sleep "$SECS"
kill $TD 2>/dev/null || true
sleep 1
echo "--- 요약 ---"
tcpdump -r "$OUT" -n -e 2>/dev/null | head -20
echo "…  Wireshark로 열기: $OUT"
