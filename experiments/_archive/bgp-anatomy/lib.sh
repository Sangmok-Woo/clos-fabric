# 단계 스크립트가 source 하는 함수 모음.  . "$(dirname "$0")/lib.sh"
# 노드 이름은 clab-bgp-*. tcpdump·iptables 는 호스트(WSL) 것을 nsenter 로 노드 netns 안에서 쓴다.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CAPDIR=$HERE/capture; mkdir -p "$CAPDIR"
WINDIR=${WINDIR:-/mnt/c/Users/sangmok/Desktop/Claude/clos-fabric/experiments/_archive/bgp-anatomy}
ROUTERS="r100 r200 r300 r400 r500 r666"
VICTIM=203.0.113.0/24

c()   { echo "clab-bgp-$1"; }
pid() { docker inspect -f '{{.State.Pid}}' "$(c "$1")"; }
nsx() { local n=$1; shift; nsenter -t "$(pid "$n")" -n "$@"; }
dx()  { local n=$1; shift; docker exec "$(c "$n")" "$@"; }
vt()  { local n=$1; shift; local a=(); for x in "$@"; do a+=(-c "$x"); done; docker exec "$(c "$n")" vtysh "${a[@]}"; }
# 설정 모드 명령: cfg r300 "router bgp 300" "neighbor ... shutdown"
cfg() { local n=$1; shift; vt "$n" "configure terminal" "$@" "end"; }
say() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
ts()  { date +%T.%3N; }

# 되돌리기: 각 단계는 바꾼 것을 끝에서 명시적으로 no 로 지운다. 여기서는 iptables 를 비우고
# 세션을 다시 맺어 soft state 를 털어낸다. (frr-reload 는 이 이미지에서 config 를 날려 쓰지 않는다)
reset_router() { nsx "$1" iptables -F 2>/dev/null; vt "$1" "clear bgp *" >/dev/null 2>&1; }
reset_all()    { for r in $ROUTERS; do nsx $r iptables -F 2>/dev/null; done; vt r100 "clear bgp *" >/dev/null 2>&1; }

# 세션 수 확인: 모두 Established 일 때까지 최대 N초
wait_up() {
  local want=$(( 7*2 )) t=${1:-90} n
  for ((i=0;i<t;i++)); do
    n=0; for r in $ROUTERS; do n=$((n + $(vt $r "show bgp summary json" | grep -c '"state":"Established"'))); done
    [ "$n" -ge "$want" ] && { echo "세션 $n/$want Established (${i}s)"; return 0; }; sleep 1
  done; echo "세션 $n/$want 만 올라옴"; return 1
}

# 캡처: cap_start <이름> <노드> <인터페이스> [BPF]  → capture/<이름>.pcap
cap_start() {
  local name=$1 node=$2 ifc=$3; shift 3; mkdir -p "$CAPDIR"
  nsenter -t "$(pid "$node")" -n tcpdump -i "$ifc" -s 512 -U -nn -w "$CAPDIR/$name.pcap" "$@" >/dev/null 2>&1 &
  echo $! >> "$CAPDIR/.pids"; sleep 0.5
}
cap_stop() {
  sleep 1; [ -f "$CAPDIR/.pids" ] && xargs -r kill < "$CAPDIR/.pids" 2>/dev/null; rm -f "$CAPDIR/.pids"; sleep 0.5
  [ -d "$WINDIR" ] && mkdir -p "$WINDIR/capture" && cp "$CAPDIR"/*.pcap "$WINDIR/capture/" 2>/dev/null; true
}

# 하이재킹 광고/철회 — r666 이 소유하지 않은 프리픽스를 자기 것으로 originate.
# blackhole(AD 10, BGP 20 보다 낮게)로 RIB 에 로컬 경로를 심어 network 가 originate 하게 하고,
# 세션에 soft-out refresh 를 걸어 r300 이 즉시 받게 한다.  hijack_add r666 r300 203.0.113.0/24 [...]
hijack_peer_ip() { case $1 in r666) echo 10.3.6.1;; r100) echo 10.1.2.2;; esac; }
hijack_add() { local atk=$1 peerip=$2; shift 2
  local af=(); for p in "$@"; do vt $atk "configure terminal" "ip route $p blackhole 10" "end" >/dev/null; af+=("network $p"); done
  vt $atk "configure terminal" "router bgp ${atk#r}" "address-family ipv4 unicast" "${af[@]}" "end" >/dev/null
  vt $atk "clear bgp $peerip" >/dev/null; sleep 5   # 새 origination 은 하드 리셋해야 광고된다
}
hijack_del() { local atk=$1 peerip=$2; shift 2
  local af=(); for p in "$@"; do af+=("no network $p"); done
  vt $atk "configure terminal" "router bgp ${atk#r}" "address-family ipv4 unicast" "${af[@]}" "end" >/dev/null
  for p in "$@"; do vt $atk "configure terminal" "no ip route $p blackhole 10" "end" >/dev/null; done
  vt $atk "clear bgp $peerip" >/dev/null; sleep 5
}

# FRR 이 설정 로드 중 일부 `neighbor X route-map Y in|out` 바인딩을 떨어뜨리는 일이 있다.
# 배포 직후 각 라우터의 frr.conf 에 있는 그 줄들을 vtysh 로 다시 박아 보장한다.
harden() {
  local D; D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  for r in $ROUTERS; do
    local asn=${r#r}
    mapfile -t lines < <(grep -E 'neighbor .* route-map .* (in|out)$' "$D/configs/$r/frr.conf")
    [ ${#lines[@]} -eq 0 ] && continue
    local cmd=("configure terminal" "router bgp $asn" "address-family ipv4 unicast")
    for l in "${lines[@]}"; do cmd+=("$(echo "$l" | sed 's/^ *//')"); done
    cmd+=("end")
    vt "$r" "${cmd[@]}" >/dev/null 2>&1
  done
  vt r100 "clear bgp * soft in" >/dev/null 2>&1; sleep 3
}
