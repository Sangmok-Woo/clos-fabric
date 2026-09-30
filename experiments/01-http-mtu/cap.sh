#!/usr/bin/env bash
# 캡처 지점 8곳(리프1 업링크 2, 스파인별 리프1·리프3 방향, 리프3 업링크 2)에서 동시에 tcpdump.
# 컨테이너에 tcpdump가 없어서 호스트 tcpdump를 nsenter로 각 컨테이너 네트워크에 꽂는다.
#
# 사용법:
#   ./cap.sh start hdr  <태그>    헤더만 (snaplen 128) — 1GB 전송용
#   ./cap.sh start full <태그>    풀 페이로드 — video-small.mp4 전송용
#   ./cap.sh stop                  멈추고 지점별 패킷 수 표 + 윈도우로 사본 복사
#   ./cap.sh count <태그>          저장된 캡처의 지점별 패킷 수 다시 보기
# 지점을 바꾸려면: POINTS="spine1:eth3 leaf3:eth1" ./cap.sh start hdr x
set -eu
. "$(dirname "$0")/lib.sh"
POINTS=${POINTS:-$CAP_POINTS}
FILTER=${FILTER:-udp port 4789}

count() {
  local dir=$PCAP/$1
  printf "  %-14s %10s %10s\n" 지점 패킷 파일크기
  for f in "$dir"/*.pcap; do
    n=$(tcpdump -nr "$f" 2>/dev/null | grep -c 'VXLAN, flags' || true)   # VXLAN은 한 패킷이 두 줄로 찍힌다
    printf "  %-14s %10s %10s\n" "$(basename "$f" .pcap)" "$n" "$(du -h "$f" | cut -f1)"
  done
}

case "${1:-}" in
  start)
    MODE=${2:?hdr|full}; TAG=${3:?태그}
    case $MODE in hdr) SNAP=128 ;; full) SNAP=0 ;; *) echo "hdr | full"; exit 1 ;; esac
    [ -f "$STATE/cap.pids" ] && { echo "이미 캡처 중. ./cap.sh stop 먼저"; exit 1; }
    mkdir -p "$PCAP/$TAG"; : > "$STATE/cap.pids"; echo "$TAG" > "$STATE/cap.tag"
    for p in $POINTS; do
      n=${p%%:*}; i=${p##*:}; out=$PCAP/$TAG/$n-$i.pcap
      nsenter -t "$(pid "$n")" -n tcpdump -i "$i" -s $SNAP -B 32768 -U -w "$out" $FILTER 2>/dev/null &
      echo $! >> "$STATE/cap.pids"
      echo "  캡처 시작 $n:$i -> pcap/$TAG/$n-$i.pcap"
    done
    sleep 1 ;;
  stop)
    [ -f "$STATE/cap.pids" ] || { echo "캡처 중이 아님"; exit 0; }
    sleep 2   # 커널 버퍼에 남은 패킷을 tcpdump가 다 읽을 시간. 바로 죽이면 끝부분(FIN 등)이 빠진다
    xargs -r kill < "$STATE/cap.pids"; sleep 1
    TAG=$(cat "$STATE/cap.tag"); rm -f "$STATE/cap.pids" "$STATE/cap.tag"
    echo "=== $TAG ==="; count "$TAG"
    mkdir -p "$WIN/$TAG" && cp "$PCAP/$TAG"/*.pcap "$WIN/$TAG/"
    echo "  윈도우 사본: experiments\\$(basename "$HERE")\\pcap\\$TAG\\" ;;
  count) count "${2:?태그}" ;;
  *) sed -n 2,11p "$0" ;;
esac
