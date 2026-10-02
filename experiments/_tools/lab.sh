# 챕터(실험 04~) 공통 도구. 각 챕터 스크립트가 source 한다.
#   . "$(dirname "$0")/../_tools/lab.sh"
# 랩 노드는 clab-clos-*. 호스트(WSL)의 iptables·nft·tcpdump 를 nsenter 로 노드 netns 안에서 쓴다
# (FRR·alpine 컨테이너에는 이 도구들이 없다).
TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HERE=$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)   # source 한 챕터 디렉터리
CAPDIR=$HERE/capture
WINROOT=/mnt/c/Users/sangmok/Desktop/Claude/clos-fabric/experiments
SNAP=${SNAP:-256}          # 캡처 길이. 헤더 흐름만 보면 되므로 짧게 (pcap 을 저장소에 올린다)

c()   { echo "clab-clos-$1"; }
pid() { docker inspect -f '{{.State.Pid}}' "$(c "$1")"; }
nsx() { local n=$1; shift; nsenter -t "$(pid "$n")" -n "$@"; }
dx()  { local n=$1; shift; docker exec "$(c "$n")" "$@"; }

# 서버(alpine)에 패키지 설치. 두 가지 함정:
#  - h1~h4 의 기본 경로는 패브릭(리프)을 향해 인터넷이 없다 → 설치하는 동안만 관리망(eth0)으로 돌렸다가 되돌린다
#  - WSL 게이트웨이 resolver 가 alpine CDN 을 자주 못 푼다 → 8.8.8.8
apk_add() {
  local h=$1; shift
  local gw; gw=$(dx "$h" ip route show default | awk '{print $3; exit}')
  local mgw; mgw=$(docker network inspect clab -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 172.20.20.1)
  dx "$h" sh -c "echo nameserver 8.8.8.8 > /etc/resolv.conf; ip route replace default via $mgw dev eth0"
  dx "$h" apk add -q --no-progress "$@"; local rc=$?
  [ -n "$gw" ] && dx "$h" ip route replace default via "$gw"
  return $rc
}

# 캡처: cap_start <이름> <노드> <인터페이스> [BPF...]  →  capture/<이름>.pcap
cap_start() {
  local name=$1 node=$2 ifc=$3; shift 3
  mkdir -p "$CAPDIR"
  # nsenter 가 tcpdump 로 exec 되므로 $! 가 곧 tcpdump 다 (함수로 감싸면 서브셸 pid 가 잡혀 안 죽는다)
  nsenter -t "$(pid "$node")" -n tcpdump -i "$ifc" -s "$SNAP" -U -nn -w "$CAPDIR/$name.pcap" "$@" >/dev/null 2>&1 &
  echo $! >> "$CAPDIR/.pids"
}
cap_stop() {
  sleep 1   # 버퍼에 남은 패킷을 tcpdump 가 다 쓸 시간
  [ -f "$CAPDIR/.pids" ] && xargs -r kill < "$CAPDIR/.pids" 2>/dev/null
  rm -f "$CAPDIR/.pids"; sleep 0.5
  for f in "$CAPDIR"/*.pcap; do printf "  %-28s %6s 패킷\n" "$(basename "$f")" "$(tcpdump -nn -r "$f" 2>/dev/null | wc -l)"; done
  # 윈도우 쪽 저장소로 사본 (Wireshark 스크린샷용)
  local win=$WINROOT/$(basename "$HERE")/capture
  [ -d "$WINROOT" ] && mkdir -p "$win" && rm -f "$win"/*.pcap && cp "$CAPDIR"/*.pcap "$win/"
}
cap_wait() { sleep "${1:-1}"; }   # tcpdump 가 붙을 시간

say() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

# 저장소에 올릴 pcap 줄이기 — head <pcap> <개수>: 앞에서 N개만 남긴다 (WSL 에는 editcap 이 없어 tcpdump 로)
head_pcap() { tcpdump -r "$1" -c "$2" -w "$1.t" 2>/dev/null && mv "$1.t" "$1"; }
