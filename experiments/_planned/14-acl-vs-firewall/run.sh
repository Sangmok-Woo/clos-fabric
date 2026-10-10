#!/bin/bash
# 실험 14 — Phase 0~6 실행. ./run.sh [0..6|all]   all 이면 capture/run-output.txt 에도 남는다.
# WSL root 에서 실행 (Phase 6이 호스트 nf_conntrack_max 를 잠깐 바꾼다).
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"; mkdir -p capture
d()  { docker exec "clab-fwacl-$1" "${@:2}"; }
db() { docker exec -d "clab-fwacl-$1" "${@:2}"; }
say(){ printf '\n=== %s ===\n' "$*"; }
ind(){ sed 's/^/    /'; }
A=10.14.10.10; B=10.14.20.10; H=10.14.1.10

# curl 한 번: "OK(200)" / "FAIL(000)"
try_curl() { local c; c=$(d "$1" curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$2/" 2>/dev/null); [ "$c" = 200 ] && echo "OK(200)" || echo "FAIL($c)"; }
try_ping() { d "$1" ping -c1 -W1 "$2" >/dev/null 2>&1 && echo OK || echo FAIL; }
matrix() {
  printf '  %-26s %-10s %-10s\n' "" "ACL쪽(A)" "FW쪽(B)"
  printf '  %-26s %-10s %-10s\n' "h1 -> server ping"       "$(try_ping h1 $A)" "$(try_ping h1 $B)"
  printf '  %-26s %-10s %-10s\n' "h1 -> server curl"       "$(try_curl h1 $A)" "$(try_curl h1 $B)"
  printf '  %-26s %-10s %-10s\n' "server -> h1 curl (선제)" "$(try_curl serverA $H)" "$(try_curl serverB $H)"
}
cnt() { d "$1" nft list ruleset 2>/dev/null | grep -o 'packets [0-9]*' | tail -1; }
drops() { echo "  drop 카운터  acl: $(cnt acl)   fw: $(cnt fw)"; }
reset_counters() { d acl nft reset counters >/dev/null 2>&1; d fw nft reset counters >/dev/null 2>&1; }
apply() { d acl nft -f /lab/nft/${1:-acl}.nft; d fw nft -f /lab/nft/fw.nft; }
servers_up() {
  for n in h1 serverA serverB; do d $n pkill -f http.server; db $n sh -c 'cd /tmp && exec python3 -m http.server 80 >/dev/null 2>&1'; done
  for n in h1 serverA serverB; do for i in $(seq 20); do d $n curl -s -m1 -o /dev/null http://127.0.0.1/ && break; sleep 0.3; done; done   # 뜰 때까지
}

p0() { say "Phase 0 — 베이스라인 (규칙 없음)"
  d acl nft flush ruleset; d fw nft flush ruleset; servers_up; matrix
  echo "  conntrack 엔트리 수  acl: $(d acl conntrack -C 2>&1)   fw: $(d fw conntrack -C 2>&1)"; }

p1() { say "Phase 1a — 같은 정책, ACL 1차 시도 (flags == ack)"
  apply acl-v1; reset_counters
  d acl timeout 5 tcpdump -nn -i eth2 -c 6 "host $A and tcp port 80" 2>/dev/null > /tmp/p1.txt & sleep 0.7
  matrix; wait; drops
  echo "  acl:eth2 (외부 쪽)에서 본 패킷 앞부분:"; head -4 /tmp/p1.txt | ind
  say "Phase 1b — ACL 고친 판 (flags & (ack|rst) != 0)"
  apply acl; reset_counters; matrix; drops; }

p2() { say "Phase 2 — 구조 들여다보기"
  echo "--- 규칙 목록 (둘 다 있다)"
  for n in acl fw; do echo "  [$n]"; d $n nft list chain inet $n forward | grep -E 'accept|counter' | sed 's/^[[:space:]]*/    /'; done
  d fw conntrack -F >/dev/null 2>&1
  d fw sysctl -qw net.netfilter.nf_conntrack_tcp_timeout_time_wait=8 && echo "--- (관찰용) fw 의 TIME_WAIT 타임아웃 120s -> 8s"
  for n in acl fw; do db $n sh -c 'timeout 14 conntrack -E -o timestamp > /tmp/ev.txt 2>&1'; done
  sleep 1; try_curl h1 $B >/dev/null; try_curl h1 $A >/dev/null
  echo "--- curl 직후 conntrack -L"
  echo "  [acl]"; d acl conntrack -L 2>&1 | ind
  echo "  [fw]";  d fw  conntrack -L 2>&1 | ind
  sleep 13
  echo "--- conntrack -E 이벤트 (14초 동안, 생성 -> 갱신 -> 소멸)"
  echo "  [acl]"; d acl cat /tmp/ev.txt | ind
  echo "  [fw]";  d fw  cat /tmp/ev.txt | ind
  d fw sysctl -qw net.netfilter.nf_conntrack_tcp_timeout_time_wait=120; }

p3() { say "Phase 3 — 위조 ACK (서버 쪽에서 h1:80 으로 ACK만 세운 패킷 3개)"
  reset_counters
  for s in serverA serverB; do
    d h1 timeout 5 tcpdump -nn -i eth1 -c 10 'tcp port 80' 2>/dev/null > /tmp/p3.txt & sleep 0.7
    out=$(d $s hping3 -A -p 80 -c 3 $H 2>&1 | grep -E 'flags=|packet loss')
    wait
    echo "  [$s -> h1]  hping3 가 받은 회신:"; echo "$out" | ind
    echo "  h1:eth1 에 찍힌 것:"; if [ -s /tmp/p3.txt ]; then ind < /tmp/p3.txt; else echo "    (아무것도 안 옴)"; fi
  done; drops; }

p4() { say "Phase 4 — UDP 왕복 (h1 -> server DNS 질의)"
  apply acl
  for s in serverA serverB; do d $s pkill dnsmasq; db $s dnsmasq -k --port=53 --no-resolv --no-hosts --address=/lab.test/10.99.99.99; done; sleep 1
  q() { local r; r=$(d h1 dig +short +time=2 +tries=1 @$1 lab.test 2>/dev/null | head -1); [[ $r == 10.* ]] && echo "OK($r)" || echo FAIL; }
  echo "  ① 지금 규칙 그대로                       ACL쪽: $(q $A)   FW쪽: $(q $B)"
  d acl nft add rule inet acl forward iifname eth2 udp sport 53 accept
  echo "  ② ACL에 'udp sport 53 accept' 추가 후    ACL쪽: $(q $A)   FW쪽: $(q $B)"
  echo "  ③ 그 구멍으로: 서버가 출발포트 53을 달고 h1의 아무 UDP 포트(9999)로 먼저 쏘기"
  for s in serverA serverB; do
    d h1 timeout 4 tcpdump -nn -i eth1 -c 5 'udp port 9999' 2>/dev/null > /tmp/p4.txt & sleep 0.7
    d $s hping3 --udp -s 53 -k -p 9999 -c 2 $H >/dev/null 2>&1; wait
    echo "    [$s -> h1:9999] h1 도착 $(grep -c '9999' /tmp/p4.txt)개"; head -1 /tmp/p4.txt | ind
  done
  echo "  FW 방명록의 UDP 엔트리:"; d fw conntrack -L -p udp 2>/dev/null | ind; }

p5() { say "Phase 5 — 비대칭 라우팅 (서버 -> h1 리턴만 우회 링크로)"
  apply acl; d fw conntrack -F >/dev/null 2>&1; reset_counters
  d serverA ip route add 10.14.1.0/24 via 10.14.40.1; d serverB ip route add 10.14.1.0/24 via 10.14.30.1
  echo "  경로: 요청 h1->leaf1->(acl|fw)->server,  응답 server->leaf1(우회)->h1"
  d fw timeout 6 tcpdump -nn -i eth1 -c 12 'tcp port 80' 2>/dev/null > /tmp/p5fw.txt &
  d h1 timeout 6 tcpdump -nn -i eth1 -c 12 "host $B and tcp port 80" 2>/dev/null > /tmp/p5h1.txt & sleep 0.7
  matrix; wait
  echo "  FW 방명록:"; d fw conntrack -L 2>/dev/null | ind
  drops
  echo "  h1:eth1 (serverB와 주고받은 것):"; head -8 /tmp/p5h1.txt | ind
  echo "  fw:eth1 (FW 내부 쪽 — 응답은 여기를 안 지난다):"; head -8 /tmp/p5fw.txt | ind
  d serverA ip route del 10.14.1.0/24; d serverB ip route del 10.14.1.0/24; echo "  (리턴 경로 원복)"; }

p6() { say "Phase 6 — conntrack 고갈"
  apply acl; for s in serverA serverB; do d $s pkill socat; db $s socat TCP-LISTEN:7000,fork,reuseaddr EXEC:cat; done; sleep 1
  d fw conntrack -F >/dev/null 2>&1
  ORIG=$(cat /proc/sys/net/netfilter/nf_conntrack_max); MAX=40
  db h1 sh -c "python3 /lab/tools/longlived.py $B 7000 25 > /tmp/ll.txt 2>&1"; sleep 2
  echo $MAX > /proc/sys/net/netfilter/nf_conntrack_max
  echo "  WSL 호스트 nf_conntrack_max $ORIG -> $MAX  (한도는 netns마다 따로 적용)"
  echo "  h1 -> 각 서버로 연결 60개를 열어 15초 붙잡는다:"
  d h1 python3 /lab/tools/hold.py $A 7000 60 15 | sed 's/^/    ACL쪽 /' &
  d h1 python3 /lab/tools/hold.py $B 7000 60 15 | sed 's/^/    FW쪽  /' & sleep 12
  echo "  FW 방명록 엔트리 수: $(d fw conntrack -C)"
  echo "  붙잡은 상태에서 새 curl   ACL쪽: $(try_curl h1 $A)   FW쪽: $(try_curl h1 $B)"
  wait
  echo "  기존 연결(longlived) 기록 마지막 5줄:"; d h1 tail -5 /tmp/ll.txt | ind
  echo "  커널 로그:"; dmesg | grep -i 'table full' | tail -2 | ind
  echo $ORIG > /proc/sys/net/netfilter/nf_conntrack_max; echo "  nf_conntrack_max 원복 -> $(cat /proc/sys/net/netfilter/nf_conntrack_max)"; }

trap '[ "$(cat /proc/sys/net/netfilter/nf_conntrack_max)" -lt 1000 ] && echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max' EXIT
case ${1:-all} in
  all) { p0; p1; p2; p3; p4; p5; p6; } 2>&1 | tee capture/run-output.txt ;;
  *)   p$1 ;;
esac
