#!/bin/bash
# 실험 09 — 세션 테이블 고갈 (NAT 포트 고갈). ./run.sh [0..5|all]  all 이면 capture/run-output.txt 에도 남는다.
#   Phase 0  기준: 포트 범위 제한 없는 SNAT. 연결 50개 + 새 curl
#   Phase 1  SNAT 포트 10개. 연결 폭주 → 기존 연결은 살고 새 연결만 실패. 같은 서버 다른 포트(8080)는?
#   Phase 2  닫힌 연결(TIME_WAIT)이 포트를 붙잡는가
#   Phase 3  사라진 클라이언트(FIN 없음) — ESTABLISHED 5일 타이머가 포트를 붙잡는다. 타임아웃·수동 삭제
#   Phase 4  UDP(DNS) 폭주 — 응답 받고 끝난 질의도 udp 타임아웃 동안 포트를 붙잡는다. 30→5초
#   Phase 5  고치기: 포트 범위 넓히기, SNAT 주소 늘리기 → 붙는 연결 수
# 캡처: nat 노드 안 tcpdump. eth2 (cli2 쪽, NAT 앞) / eth3 (srv 쪽, NAT 뒤) / eth1 (cli1 쪽)
# 바꾸는 값은 전부 랩 컨테이너 netns 안(nat 의 nft 규칙·conntrack 타임아웃·보조 주소, cli1 의 송신 차단)이다.
# WSL 호스트 값은 건드리지 않는다.
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"; CAPDIR=$HERE/capture; ST=$HERE/state; mkdir -p "$CAPDIR" "$ST"
d()  { docker exec "clab-natlab-$1" "${@:2}"; }
di() { docker exec -i "clab-natlab-$1" "${@:2}"; }
db() { docker exec -d "clab-natlab-$1" "${@:2}"; }
say(){ printf '\n=== %s ===\n' "$*"; }
ind(){ sed 's/^/    /'; }
SRV=10.9.100.10
TS(){ date +%s.%N; }
el(){ awk -v a="$1" -v b="$(TS)" 'BEGIN{printf "%.1f", b-a}'; }

# --- 원래 값 기록 (restore.sh 가 쓴다)
SYS="net.netfilter.nf_conntrack_tcp_timeout_time_wait net.netfilter.nf_conntrack_tcp_timeout_established net.netfilter.nf_conntrack_udp_timeout"
[ -f "$ST/sysctl" ] || d nat sysctl $SYS > "$ST/sysctl"
sys_restore() { while read -r k _ v; do d nat sysctl -qw "$k=$v"; done < "$ST/sysctl"; }
restore_nat() {
  sys_restore
  d nat nft flush ruleset; d nat ip addr del 10.9.100.2/24 dev eth3 2>/dev/null; d nat ip addr del 10.9.100.3/24 dev eth3 2>/dev/null
  d cli1 nft flush ruleset; d nat conntrack -F >/dev/null 2>&1
}

# SNAT 규칙: snat <대상>   예) snat 10.9.100.1:20000-20009   (ICMP 는 포트 없이 같은 주소로)
snat() {
  d nat nft flush ruleset
  printf 'table ip nat {\n  chain post {\n    type nat hook postrouting priority srcnat;\n    oifname "eth3" meta l4proto { tcp, udp } snat to %s\n    oifname "eth3" snat to %s\n  }\n}\n' "$1" "${1%%:*}" | di nat nft -f -
  d nat conntrack -F >/dev/null 2>&1
}
block_cli1() { printf 'table inet blk {\n  chain out {\n    type filter hook output priority 0;\n    oifname "eth1" drop\n  }\n}\n' | di cli1 nft -f -; }
# conntrack -S 의 CPU별 줄을 더한다
ctS() { d nat conntrack -S | tr ' \t' '\n\n' | awk -F= '$1~/^(insert_failed|drop|early_drop|clash_resolve)$/{s[$1]+=$2} END{printf "conntrack -S 합계: insert_failed=%d drop=%d early_drop=%d clash_resolve=%d", s["insert_failed"],s["drop"],s["early_drop"],s["clash_resolve"]}'; }
ctD() { d nat conntrack -S | tr ' \t' '\n\n' | awk -F= '$1=="insert_failed"{s+=$2} END{print s+0}'; }
ctN() { d nat conntrack -L -p "${1:-tcp}" 2>/dev/null | grep -c .; }
states() { d nat conntrack -L -p tcp 2>/dev/null | awk '{print $4}' | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}'; }
ports() { d nat conntrack -L -p "${1:-tcp}" 2>/dev/null | grep -o 'dst=10\.9\.100\.[123] sport=[0-9]* dport=[0-9]*' | awk '{print $1":"$3}' | sort -u | wc -l; }
# curl 한 번 (cli2): "200 connect=0.000s total=0.001s"
probe() { d cli2 curl -s -m "${2:-5}" -o /dev/null -w '%{http_code} connect=%{time_connect}s total=%{time_total}s' "http://$SRV:${1:-80}/"; }
# 연결 붙잡기: hog <노드> <로그이름> <N> [hog.py 추가 인자]   (호스트 쪽 백그라운드, 로그는 state/)
hog() { local n=$1 log=$ST/$2.log; shift 2; rm -f "$log"; ( d "$n" python3 -u /lab/tools/hog.py $SRV 80 "$@" > "$log" 2>&1 & ); }
hog_stop() { d "$1" pkill -"${2:-TERM}" -f hog.py 2>/dev/null; sleep 1; }
hog_wait() { for i in $(seq 40); do grep -q connect "$ST/$1.log" 2>/dev/null && break; sleep 0.5; done; grep connect "$ST/$1.log" | sed 's/^/  /'; }
alive() { echo "  [$1] $(grep alive "$ST/$1.log" | tail -1)"; }
srv_up() {
  d srv pkill -f srv.py; d srv pkill dnsmasq
  db srv python3 /lab/tools/srv.py
  db srv dnsmasq -k --port=53 --no-resolv --no-hosts --address=/lab.test/10.99.99.99
  sleep 1
}
cap_start() { db nat tcpdump -i "$2" -s 128 -U -nn -w "/tmp/$1.pcap" "${@:3}"; sleep 0.7; }
cap_stop()  { sleep 0.5; d nat pkill tcpdump; sleep 0.5
  for f in "$@"; do docker cp -q "clab-natlab-nat:/tmp/$f.pcap" "$CAPDIR/$f.pcap"; printf '  %-24s %4s 패킷\n' "$f.pcap" "$(tcpdump -nn -r "$CAPDIR/$f.pcap" 2>/dev/null | wc -l)"; done; }
q() { d "$1" dig +short +time=1 +tries=1 @$SRV lab.test 2>/dev/null | grep -q '^10\.99' && echo OK || echo FAIL; }

p0() { say "Phase 0 — 기준: 포트 범위 제한 없는 SNAT (10.9.100.1)"
  restore_nat; srv_up
  echo "  NAT 없이 cli2 -> srv:   $(probe 80 2)   (srv 는 안쪽 경로를 모른다)"
  snat 10.9.100.1
  echo "  SNAT 후 cli2 -> srv:    $(probe)"
  hog cli1 p0 50 --src 10.9.1.10-19 --ping 2; hog_wait p0
  echo "  conntrack 엔트리(tcp) $(ctN)개, 서로 다른 (NAT주소:포트) $(ports)개"
  echo "  엔트리 예 (안쪽 출발 포트 → 바깥 포트):"
  d nat conntrack -L -p tcp 2>/dev/null | head -3 | awk '{print "    "$5,$7,"→",$10,$12}'
  echo "  50개 붙잡힌 상태에서 새 curl: $(probe)"
  echo "  $(ctS)  (netns 가 생긴 뒤 누적)"
  hog_stop cli1; }

p1() { say "Phase 1 — SNAT 포트 10개 (10.9.100.1:20000-20009)"
  snat 10.9.100.1:20000-20009; srv_up
  hog cli2 p1-old 1 --ping 1; hog_wait p1-old; echo "  ↑ cli2 의 '기존 사용자' 연결 1개 (1초마다 PING/PONG)"
  hog cli1 p1 20 --src 10.9.1.10-19 --ctimeout 3 --ping 2; hog_wait p1; echo "  ↑ cli1 이 20개를 동시에 시도"
  echo "  conntrack 엔트리(tcp) $(ctN)개, 쓰인 바깥 포트 $(ports)개"
  echo "  바깥 포트 목록: $(d nat conntrack -L -p tcp 2>/dev/null | grep -o 'dport=200[0-9][0-9]' | cut -d= -f2 | sort -n | tr '\n' ' ')"
  echo "  cli2 의 SYN 재전송 설정: $(d cli2 sysctl net.ipv4.tcp_syn_retries net.ipv4.tcp_syn_linear_timeouts 2>&1 | paste -sd' ')"
  local f0; f0=$(ctD)
  cap_start p1-in eth2 tcp and host 10.9.2.10; cap_start p1-out eth3 'tcp[tcpflags] & tcp-syn != 0'
  echo "  새 연결 cli2 -> srv:80  ① $(probe)"
  echo "                          ② $(probe)"
  echo "  같은 서버 다른 포트 cli2 -> srv:8080  $(probe 8080)"
  alive p1-old; alive p1
  echo "  insert_failed 증가: $(( $(ctD) - f0 ))   (curl 세 번 동안)"
  echo "  --- 30초 기다리는 curl 을 걸어 두고 5초 뒤 cli1 연결을 정상 종료(FIN)"
  local t0; t0=$(TS)
  ( d cli2 curl -s -m 30 -o /dev/null -w '%{http_code} connect=%{time_connect}s total=%{time_total}s' "http://$SRV/" > "$ST/p1-wait.txt" ) &
  sleep 5; hog_stop cli1; echo "  cli1 종료 시각 +$(el $t0)s"
  wait; echo "  기다린 curl: $(cat "$ST/p1-wait.txt")"
  cap_stop p1-in p1-out
  echo "  NAT 앞(eth2)에서 본 cli2 의 SYN (첫 SYN 기준 시각):"
  tcpdump -nn -tt -r "$CAPDIR/p1-in.pcap" 'tcp[tcpflags] == tcp-syn and src host 10.9.2.10' 2>/dev/null | awk 'NR==1{t=$1} {printf "    +%6.3fs  %s > %s\n", $1-t, $3, $5}'
  echo "  NAT 뒤(eth3)로 나간 SYN (같은 시간):"
  tcpdump -nn -tt -r "$CAPDIR/p1-out.pcap" 'tcp[tcpflags] == tcp-syn' 2>/dev/null | awk '{printf "    %s > %s\n", $3, $5}'
  echo "  $(ctS)"
  hog_stop cli2; }

p2() { say "Phase 2 — 닫힌 연결(TIME_WAIT)이 포트를 붙잡는가 (time_wait 타임아웃 $(d nat sysctl -n net.netfilter.nf_conntrack_tcp_timeout_time_wait)s 그대로)"
  snat 10.9.100.1:20000-20009
  hog cli1 p2 10 --src 10.9.1.10-19 --ping 2; hog_wait p2
  echo "  열린 상태에서 새 curl: $(probe 80 3)"
  hog_stop cli1; sleep 1
  echo "  ① 클라이언트가 먼저 닫음(FIN). 직후 엔트리: $(states)"
  d nat conntrack -L -p tcp 2>/dev/null | head -1 | awk '{print "    예: "$3"초 남음 "$4,$5,$7,"→",$10,$12}'
  local f0; f0=$(ctD)
  for i in 1 2 3; do echo "    TIME_WAIT 10개 남은 채 새 curl ($i): $(probe 80 3)"; done
  echo "    insert_failed 증가: $(( $(ctD) - f0 ))   엔트리: $(states)"
  echo "    새 curl 이 받은 바깥 포트: $(d nat conntrack -L -p tcp --orig-src 10.9.2.10 2>/dev/null | grep -o 'dport=200[0-9][0-9]' | cut -d= -f2 | tr '\n' ' ')"
  echo "  ② 서버가 먼저 닫음 (srv.py 는 HTTP 응답 뒤 먼저 닫는다). cli1 에서 curl 10번"
  d nat conntrack -F >/dev/null 2>&1
  for i in $(seq 10); do d cli1 curl -s -m 2 -o /dev/null "http://$SRV/"; done
  echo "    직후 엔트리: $(states)"
  f0=$(ctD)
  for i in 1 2 3; do echo "    새 curl ($i): $(probe 80 3)"; done
  echo "    insert_failed 증가: $(( $(ctD) - f0 ))   엔트리: $(states)"; }

p3() { say "Phase 3 — 사라진 클라이언트: FIN 없이 사라지면 ESTABLISHED 타이머($(d nat sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established)s)가 포트를 붙잡는다"
  snat 10.9.100.1:20000-20009
  hog cli1 p3 10 --src 10.9.1.10-19 --ping 1; hog_wait p3; sleep 1.5
  block_cli1; local t0; t0=$(TS); hog_stop cli1 KILL
  echo "  cli1 이 선을 뽑힌 것처럼 사라짐 (cli1 송신 DROP + 프로세스 강제 종료 → FIN 이 못 나간다)"
  echo "  엔트리: $(states) 남은 시간 예: $(d nat conntrack -L -p tcp 2>/dev/null | head -1 | awk '{print $3}')s"
  echo "  +$(el $t0)s 새 curl: $(probe 80 3)"
  echo "  ① established 타임아웃을 지금 20s 로 낮춰 본다 (이미 있는 엔트리에 먹히나?)"
  d nat sysctl -qw net.netfilter.nf_conntrack_tcp_timeout_established=20
  sleep 25; echo "    +$(el $t0)s 엔트리 $(ctN)개, 남은 시간 예: $(d nat conntrack -L -p tcp 2>/dev/null | head -1 | awk '{print $3}')s, 새 curl: $(probe 80 3)"
  echo "  ② 수동 삭제: conntrack -D --reply-port-dst 20000 (바깥 포트 하나만)"
  d nat conntrack -D -p tcp --reply-port-dst 20000 2>&1 | tail -1 | ind
  echo "    +$(el $t0)s 새 curl: $(probe 80 3)"
  echo "  ③ 처음부터 established=20s 로 두고 다시. 사라진 뒤 1초 curl 을 반복해 첫 성공 시각"
  d nat conntrack -F >/dev/null 2>&1; d cli1 nft flush ruleset
  hog cli1 p3b 10 --src 10.9.1.10-19 --ping 1; hog_wait p3b; sleep 1.5
  block_cli1; t0=$(TS); hog_stop cli1 KILL
  local r="" i; for i in $(seq 40); do r=$(probe 80 1); [ "${r%% *}" = 200 ] && break; done
  echo "    사라진 뒤 +$(el $t0)s 에 첫 성공: $r  (시도 $i번)"
  d cli1 nft flush ruleset; d nat conntrack -F >/dev/null 2>&1; sys_restore; }

p4() { say "Phase 4 — UDP(DNS): 질의 하나가 끝나도 udp 타임아웃 동안 포트를 붙잡는다"
  snat 10.9.100.1:20000-20009; srv_up
  local to t0 res f0 i
  for to in $(d nat sysctl -n net.netfilter.nf_conntrack_udp_timeout) 5; do
    d nat sysctl -qw net.netfilter.nf_conntrack_udp_timeout=$to; d nat conntrack -F >/dev/null 2>&1
    echo "  --- udp 타임아웃 ${to}s: cli1 이 질의 20개를 연달아 (매번 새 출발 포트, 1초 대기·재시도 없음)"
    if [ "$to" != 5 ]; then cap_start p4-in eth1 udp port 53; cap_start p4-out eth3 udp port 53; fi
    t0=$(TS); f0=$(ctD); res=""
    for i in $(seq 20); do [ "$(q cli1)" = OK ] && res="${res}o" || res="${res}x"; done
    echo "  결과 (o 성공 x 실패): $res   $(echo "$res" | tr -cd o | wc -c)/20  (+$(el $t0)s)"
    echo "  udp 엔트리 $(ctN udp)개, 쓰인 바깥 포트 $(ports udp)개, insert_failed +$(( $(ctD) - f0 ))"
    d nat conntrack -L -p udp 2>/dev/null | head -1 | awk '{print "    예: "$3"초 남음 "$4,$6,"→",$9,$11,$12}'
    if [ "$to" != 5 ]; then cap_stop p4-in p4-out; fi
    for i in $(seq 90); do [ "$(q cli2)" = OK ] && break; done
    echo "  cli2(다른 사용자) 질의: 첫 질의 기준 +$(el $t0)s 에 첫 성공 (실패 $((i-1))번 뒤)"
  done
  sys_restore; }

p5() { say "Phase 5 — 고치기: 범위·주소를 늘리면 몇 개까지 붙나 (동시 시도, ctimeout 3s)"
  capa() { d nat conntrack -F >/dev/null 2>&1; hog cli1 p5 "$2" $3 --ctimeout 3 --ping 5
    hog_wait p5 >/dev/null; local c; c=$(grep connect "$ST/p5.log" | awk '{print $3}')
    printf '  %-34s 시도 %3s → 붙음 %-8s 바깥 주소별: %s\n' "$1" "$2" "$c" \
      "$(d nat conntrack -L -p tcp 2>/dev/null | grep -o 'dst=10\.9\.100\.[123] sport=80' | cut -d' ' -f1 | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}' | sed 's/dst=10.9.100././g')"
    hog_stop cli1; }
  d nat ip addr add 10.9.100.2/24 dev eth3; d nat ip addr add 10.9.100.3/24 dev eth3
  snat 10.9.100.1:20000-20009;            capa "주소 1개 × 포트 10개, 출발지 1개"   20 "--src 10.9.1.10-10"
  snat 10.9.100.1:20000-20099;            capa "주소 1개 × 포트 100개, 출발지 10개" 150 "--src 10.9.1.10-19"
  snat 10.9.100.1-10.9.100.3:20000-20009; capa "주소 3개 × 포트 10개, 출발지 1개"   40 "--src 10.9.1.10-10"
  snat 10.9.100.1-10.9.100.3:20000-20009; capa "주소 3개 × 포트 10개, 출발지 10개"  40 "--src 10.9.1.10-19"
  echo "  주소 3개 규칙에서 안쪽 주소마다 어느 바깥 주소로 묶이나 (주소마다 :80 한 번씩):"
  d nat conntrack -F >/dev/null 2>&1
  for i in $(seq 10 19); do d cli1 curl -s -m 2 -o /dev/null --interface 10.9.1.$i "http://$SRV/"; done
  d nat conntrack -L -p tcp 2>/dev/null | awk '{s="";o="";p="";for(i=1;i<=NF;i++){if($i~/^src=/&&s=="")s=$i; if($i~/^dport=/&&p=="")p=$i; if($i~/^dst=10\.9\.100\.[123]$/)o=$i} print s":"p" → "o}' | sed 's/src=//; s/dport=//; s/dst=//' | sort -V | paste - - - - - | ind
  restore_nat
  snat 10.9.100.1:20000-20099
  echo "  포트 100개로 넓힌 뒤 cli1 20개 + cli2 새 curl:"; hog cli1 p5b 20 --src 10.9.1.10-19 --ctimeout 3; hog_wait p5b
  echo "    $(probe)"; hog_stop cli1; }

run() { case $1 in 0) p0;; 1) p1;; 2) p2;; 3) p3;; 4) p4;; 5) p5;; esac; }
if [ "${1:-all}" = all ]; then
  exec > >(tee "$CAPDIR/run-output.txt") 2>&1
  echo "실행 $(date '+%F %T')  커널 $(uname -r)"
  echo "nat 원래 값: $(tr '\n' ' ' < "$ST/sysctl")"
  for p in 0 1 2 3 4 5; do run $p; done
  say "원복"; d cli1 pkill -f hog.py; d cli2 pkill -f hog.py; restore_nat
  echo "  nat: $(d nat sysctl $SYS | tr '\n' ' ')"
  echo "  nat nft 규칙 줄 수: $(d nat nft list ruleset | wc -l), eth3 주소: $(d nat ip -4 -o addr show eth3 | wc -l)개, cli1 nft 줄 수: $(d cli1 nft list ruleset | wc -l)"
else run "$1"; fi
