#!/usr/bin/env bash
# 스파인이 조용히 먹통이 될 때 — BGP 타이머만으로 vs BFD 300ms×3.
# h1 → h4 ping 이 지금 타는 스파인을 찾아 얼린다: 포워딩을 끄고(패킷을 버림) 컨테이너를 멈춘다(BGP·BFD 가 조용히 멎음).
# 링크는 up 그대로라 인터페이스 다운으로는 알 수 없다. 같은 장애를 두 번 넣는다.
#   Phase nobfd  BGP timers 3/9 만으로 감지
#   Phase bfd    scripts/bfd-apply.sh on (300ms × 3) 뒤 같은 장애
#
# Phase 시간표 (T0 = 먹통)
#   T0-4    ping 시작 (0.05초 간격)
#   T0      spineN ip_forward=0 + docker pause
#   T0+15   복구 (unpause + ip_forward=1)
#   T0+35   ping 끝. 세션이 다시 붙을 때까지 기다린 뒤 다음 Phase
# 캡처: h1:eth1 (ICMP), leaf1·leaf4 의 BGP+BFD (tcp 179, udp 3784)
set -u
. "$(dirname "$0")/../_tools/lab.sh"
. "$TOOLS/timeline.sh"
SNAP=200
DST=172.16.14.10
BFD=$(cd "$HERE/../.." && pwd)/scripts/bfd-apply.sh
ST=$HERE/state; rm -rf "$CAPDIR" "$ST"; mkdir -p "$CAPDIR" "$ST"
exec > >(tee "$CAPDIR/run-output.txt") 2>&1

tx() { dx "$1" cat "/sys/class/net/$2/statistics/tx_packets"; }
active() {
  local a1 a2 b1 b2; b1=$(tx "$1" eth1); b2=$(tx "$1" eth2)
  dx h1 ping -c 20 -i 0.05 -q $DST >/dev/null 2>&1
  a1=$(tx "$1" eth1); a2=$(tx "$1" eth2)
  [ $((a1-b1)) -ge $((a2-b2)) ] && echo 1 || echo 2
}
# 데이터가 실린 TCP 세그먼트만 (BGP 메시지). 얼린 스파인도 커널은 살아 있어 빈 ACK 는 계속 보낸다
PAYLOAD='(((ip[2:2] - ((ip[0]&0xf)<<2)) - ((tcp[12]&0xf0)>>2)) != 0)'
established() { dx leaf1 vtysh -c "show ip bgp summary" | grep -cE '^spine[12].* [0-9]+ +[0-9]+ +spine'; }
wait_sessions() {
  for _ in $(seq 60); do [ "$(established)" = 2 ] && return 0; sleep 1; done
  echo "  (세션이 60초 안에 다 붙지 않았다)"
}

run_phase() {   # run_phase <tag>
  local tag=$1 S P T0
  say "Phase $tag — 경로 확인"
  A=$(active leaf1); R=$(active leaf4); S=spine$A
  echo "  요청 h1→h4: leaf1 eth$A → spine$A   응답 h4→h1: leaf4 eth$R → spine$R"
  echo "  얼릴 장비: $S"
  dx leaf1 vtysh -c "show bfd peers brief" | grep -E 'up|down' | sed 's/^/  BFD /'
  cap_start "$tag-h1-eth1"   h1    eth1 icmp
  SNAP=0 cap_start "$tag-leaf1-ctl" leaf1 any tcp port 179 or udp port 3784
  SNAP=0 cap_start "$tag-leaf4-ctl" leaf4 any tcp port 179 or udp port 3784
  cap_wait 1
  docker exec -d "$(c h1)" sh -c "ping -i 0.05 -c 760 $DST > /tmp/ping14.txt 2>&1"
  sleep 4
  P=$(pid "$S")
  T0=$(now); nsenter -t "$P" -n sysctl -qw net.ipv4.ip_forward=0; docker pause "$(c "$S")" >/dev/null
  echo "$T0" > "$ST/$tag.T0"; cp "$ST/$tag.T0" "$CAPDIR/"   # Wireshark 에서 T0 를 찾을 때 쓴다
  say "T0 $S 먹통 (ip_forward=0 + docker pause, 링크는 up)"
  sleep 15
  docker unpause "$(c "$S")" >/dev/null; nsenter -t "$P" -n sysctl -qw net.ipv4.ip_forward=1
  say "T0+15 $S 복구"
  sleep 20
  cap_stop
  say "Phase $tag 결과"
  dx h1 tail -2 /tmp/ping14.txt | head -1 | sed 's/^/  /'
  echo "  응답 없는 요청: $(lost "$CAPDIR/$tag-h1-eth1.pcap") 개 (0.05초 간격)"
  echo "  $(reply_gap "$CAPDIR/$tag-h1-eth1.pcap" "$T0")"
  echo "  -- leaf1 BGP·BFD (keepalive 제외, T0-1 ~ T0+14) --"
  bgp_events "$CAPDIR/$tag-leaf1-ctl.pcap" "$T0" -1 14
  echo "  -- leaf4 BGP·BFD --"
  bgp_events "$CAPDIR/$tag-leaf4-ctl.pcap" "$T0" -1 14
  echo "  -- $S 가 leaf1 에 보낸 마지막 BGP 메시지 / BFD (T0 기준) --"
  local ip; ip=$(dx leaf1 vtysh -c "show ip bgp summary" | awk -v s="$S" '$0 ~ "^"s"\\(" {sub(/^[^(]*\(/,"",$1); sub(/\).*/,"",$1); print $1}')
  echo "    BGP: $(tcpdump -tt -nn -r "$CAPDIR/$tag-leaf1-ctl.pcap" "src $ip and tcp port 179 and $PAYLOAD" 2>/dev/null | awk -v t0="$T0" '$1<t0+14{l=$1} END{printf "T0%+.3f", l-t0}')"
  echo "    BFD: $(tcpdump -tt -nn -r "$CAPDIR/$tag-leaf1-ctl.pcap" "src $ip and udp port 3784" 2>/dev/null | awk -v t0="$T0" '$1<t0+14{l=$1} END{if(l) printf "T0%+.3f", l-t0; else print "-"}')"
  say "세션 재수립 대기"; wait_sessions; echo "  leaf1 Established $(established)/2"
}

run_phase nobfd
say "BFD 적용"; "$BFD" on | tail -4; sleep 5
run_phase bfd
say "원복 — BFD 해제"; "$BFD" off | tail -3
wait_sessions; echo "  leaf1 Established $(established)/2"
