#!/usr/bin/env bash
# DNS 장애. h4 에 DNS 서버(dnsmasq)를 띄우고 h1 이 web.lab(= h3 웹서버)을 이름으로 찾아간다.
#   Phase ok       정상                         web.lab → 172.16.13.10
#   Phase stale    잘못된 레코드                 web.lab → 172.16.13.99 (이미 없어진 서버)
#   Phase down     DNS 프로세스가 죽음            포트가 닫혀 있다
#   Phase silent   서버는 살아 있는데 응답이 없음  방화벽이 53번을 조용히 버린다
# 각 Phase 에서 이름으로 한 번, IP 로 한 번 접속해 본다.
# 캡처: h1:eth1 (클라이언트), h4:eth1 (DNS 서버), stale 에서는 leaf3:eth3 (없는 서버 쪽)
set -u
. "$(dirname "$0")/../_tools/lab.sh"
rm -rf "$CAPDIR"; mkdir -p "$CAPDIR"
DNS=172.16.14.10

dns_start() {   # dns_start <web.lab 의 주소>
  # --user=root: 기본으로는 권한을 내려놓아 재시작 때 로그 파일을 못 연다(첫 실행에서 걸림)
  dx h4 sh -c "pkill -x dnsmasq; sleep 0.3; dnsmasq --user=root --no-resolv --no-hosts --listen-address=$DNS --bind-interfaces \
    --host-record=web.lab,$1 --log-queries --log-facility=/tmp/dnsmasq.log"
}
try() {   # 이름과 IP 로 각각 한 번씩 접속
  local t0 t1 out
  t0=$(date +%s.%N)
  out=$(dx h1 sh -c 'curl -s -o /dev/null --max-time 20 -w "%{http_code}" http://web.lab/; echo " exit=$?"')
  t1=$(date +%s.%N)
  printf "  이름(web.lab)    : HTTP %s  %.1f초
" "$out" "$(echo "$t1 - $t0" | bc)"
  printf "  IP(172.16.13.10) : HTTP %s
" "$(dx h1 curl -s -o /dev/null --max-time 5 -w '%{http_code}' http://172.16.13.10/)"
}
phase() {   # phase <이름> <설명>
  say "Phase $1 — $2"
  cap_start "$1-h1" h1 eth1 udp port 53 or tcp port 80 or icmp or arp
  cap_start "$1-h4" h4 eth1 udp port 53 or icmp
  [ "$1" = stale ] && cap_start "$1-leaf3" leaf3 eth3 arp or icmp or tcp port 80
  cap_wait 1
}

OLDRES=$(dx h1 cat /etc/resolv.conf)
dx h1 sh -c "echo nameserver $DNS > /etc/resolv.conf"

dx h4 rm -f /tmp/dnsmasq.log
dns_start 172.16.13.10
phase ok "정상"; try; cap_stop

dns_start 172.16.13.99
phase stale "잘못된 레코드 web.lab → 172.16.13.99"; try; cap_stop

dx h4 pkill -x dnsmasq
phase down "DNS 프로세스 중지"; try; cap_stop

dns_start 172.16.13.10
nsx h4 iptables -I INPUT -p udp --dport 53 -j DROP
phase silent "53번을 조용히 버림 (iptables DROP)"; try; cap_stop
nsx h4 iptables -D INPUT -p udp --dport 53 -j DROP

say "원복"
dns_start 172.16.13.10
try
dx h1 sh -c "printf '%s\n' \"$OLDRES\" > /etc/resolv.conf"
echo "  DNS 서버 로그 (마지막 5줄):"; dx h4 tail -5 /tmp/dnsmasq.log | sed 's/^/    /'
