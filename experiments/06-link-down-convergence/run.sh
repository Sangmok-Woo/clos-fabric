#!/usr/bin/env bash
# 링크 다운 수렴. h1 → h4 ping 이 지금 타는 스파인을 찾아, leaf1 쪽에서 그 링크를 내린다(케이블 단선).
# 0.05초 간격 ping 을 흘리며 끊긴 시간과, 그 사이 라우팅·BGP 가 무엇을 했는지를 캡처로 본다.
#
# 시간표 (T0 = 링크 다운)
#   T0-4    ping 시작 (0.05초 간격)
#   T0      leaf1:ethN down
#   T0+8    leaf1:ethN up   (복구 — 세션이 다시 붙는 동안에도 끊기는지)
#   T0+30   ping 끝
# 캡처 지점:
#   h1:eth1            ping 요청·응답 (끊긴 구간)
#   leaf1:<남은 링크>   우회한 트래픽이 언제부터 이쪽으로 오는지
#   leaf1 BGP, leaf4 BGP   세션·UPDATE (리턴 경로의 리프가 언제 소식을 듣는지)
#   leaf1·leaf4 커널 라우팅 변경 (ip -ts monitor route)
set -u
. "$(dirname "$0")/../_tools/lab.sh"
. "$TOOLS/timeline.sh"
SNAP=200
SRC=172.16.11.10 DST=172.16.14.10
ST=$HERE/state; rm -rf "$CAPDIR" "$ST"; mkdir -p "$CAPDIR" "$ST"
exec > >(tee "$CAPDIR/run-output.txt") 2>&1

tx() { dx "$1" cat "/sys/class/net/$2/statistics/tx_packets"; }
active() {   # active <리프>  → 지금 ping 이 그 리프에서 나가는 업링크 번호 (1|2)
  local a1 a2 b1 b2; b1=$(tx "$1" eth1); b2=$(tx "$1" eth2)
  dx h1 ping -c 20 -i 0.05 -q $DST >/dev/null 2>&1
  a1=$(tx "$1" eth1); a2=$(tx "$1" eth2)
  [ $((a1-b1)) -ge $((a2-b2)) ] && echo 1 || echo 2
}

say "준비 — 경로 확인"
A=$(active leaf1); R=$(active leaf4); O=$((3 - A))
echo "  요청 h1→h4: leaf1 eth$A → spine$A"
echo "  응답 h4→h1: leaf4 eth$R → spine$R"
echo "  끊을 링크: leaf1:eth$A ↔ spine$A   (남는 링크 leaf1:eth$O)"
echo "$A" > "$ST/active"

cap_start h1-eth1        h1    eth1 icmp
cap_start leaf1-eth$O    leaf1 eth$O icmp
SNAP=0 cap_start leaf1-bgp leaf1 any tcp port 179
SNAP=0 cap_start leaf4-bgp leaf4 any tcp port 179
route_log() { nsx "$1" stdbuf -oL ip monitor route | while read -r l; do echo "$(now) $l"; done > "$ST/$1-route"; }
route_log leaf1 & echo $! >> "$ST/pids"
route_log leaf4 & echo $! >> "$ST/pids"
cap_wait 1

docker exec -d "$(c h1)" sh -c "ping -i 0.05 -c 680 $DST > /tmp/ping13.txt 2>&1"
sleep 4
# docker exec 는 시작까지 0.1~0.2초 걸려 T0 가 어긋난다(첫 실행에서 확인). netns 에 직접 들어가 내린다
P1=$(pid leaf1)
T0=$(now); nsenter -t "$P1" -n ip link set "eth$A" down; echo "$T0" > "$ST/T0"
say "T0 leaf1:eth$A down — 케이블 단선"
sleep 8
T1=$(now); echo "$T1" > "$ST/T1"
say "T0+$(awk -v a=$T0 -v b=$T1 'BEGIN{printf "%.1f", b-a}') leaf1:eth$A up — 복구"
nsx leaf1 ip link set "eth$A" up
sleep 23
xargs -r kill < "$ST/pids" 2>/dev/null; pkill -f "ip monitor route" 2>/dev/null
cap_stop

say "결과"
dx h1 tail -2 /tmp/ping13.txt
echo "  응답 없는 요청: $(lost "$CAPDIR/h1-eth1.pcap") 개 (0.05초 간격)"
echo "  $(reply_gap "$CAPDIR/h1-eth1.pcap" "$T0")"
first=$(tcpdump -tt -nn -r "$CAPDIR/leaf1-eth$O.pcap" "icmp[icmptype]==icmp-echo and src $SRC" 2>/dev/null \
        | awk -v t0="$T0" '$1>t0{printf "%+.3f", $1-t0; exit}')
echo "  남은 링크 leaf1:eth$O 로 첫 요청이 나간 시각: T0${first:- (없음)}"
say "커널 라우팅 변경 (172.16.14.0/24 @leaf1, 172.16.11.0/24 @leaf4)"
for n in leaf1 leaf4; do
  awk -v t0="$T0" -v n=$n '{ r=$1-t0; if (r>-1 && r<30) { $1=""; printf "  %s T0%+.3f %s\n", n, r, $0 } }' "$ST/$n-route" | head -8
done
say "leaf1 BGP (keepalive 제외)"; bgp_events "$CAPDIR/leaf1-bgp.pcap" "$T0" -1 30
say "leaf4 BGP (keepalive 제외)"; bgp_events "$CAPDIR/leaf4-bgp.pcap" "$T0" -1 30
say "복구 후 세션"
dx leaf1 vtysh -c "show ip bgp summary" | grep -E '^spine'
cp "$ST/T0" "$ST/T1" "$ST/leaf1-route" "$ST/leaf4-route" "$CAPDIR/" 2>/dev/null
