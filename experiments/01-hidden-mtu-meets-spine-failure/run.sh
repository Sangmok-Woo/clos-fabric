#!/usr/bin/env bash
# 숨어 있던 MTU 결함 + 스파인 한 대의 조용한 먹통.
# spine2 의 leaf3 방향 포트 MTU 가 1500 으로 잘못 들어가 있는데(평소엔 절반 트래픽만 아프다),
# 그 상태에서 spine1 이 조용히 죽으면 모든 트래픽이 spine2 로 몰려 결함을 정면으로 맞는다.
#
# 시간표 (초)
#   P0 정상                                   20
#   P1 숨은 결함: spine2:eth3 MTU 1500         30
#   P2 + spine1 조용한 먹통 (포워딩 끔 + 정지)   45
#   P3 spine1 복구 (MTU 결함은 그대로)          30
#   P4 MTU 복구                                20
# 그동안 h1 → h3 로 0.5초마다 HTTP 1MB 를 받고, 따로 0.5초마다 작은 ping 을 보낸다.
# 끝나면 report.py 가 Phase 별 성공률과 모니터링 알람 시각을 정리한다.
#
# REHASH=0 ./run.sh  — 서버의 TCP 경로 재선택(net.core.txrehash)을 끄고 돌린다.
#   리눅스 TCP 는 재전송 타임아웃 때 패킷의 해시값을 바꾸고, veth 는 그 값을 리프까지 그대로 넘긴다.
#   리프는 그 값으로 ECMP 경로를 고르므로 재전송이 다른 스파인으로 빠져나간다(첫 실행에서 발견).
#   진짜 스위치는 헤더로 해시를 계산해 같은 연결은 늘 같은 길로 간다 → REHASH=0 이 그쪽에 가깝다.
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=128
REHASH=${REHASH:-1}
CAPDIR=$HERE/capture/rehash$REHASH
ST=$HERE/state/rehash$REHASH; rm -rf "$CAPDIR" "$ST"; mkdir -p "$CAPDIR" "$ST"
mark() { echo "$1 $(date +%s.%N)" >> "$ST/timeline"; say "$1 — $2"; }

# ECMP 해시를 L4 로 (연결마다 다른 스파인) — 원래 값은 되돌린다
for n in leaf1 leaf2 leaf3 leaf4; do echo "$n $(dx $n sysctl -n net.ipv4.fib_multipath_hash_policy)"; done > "$ST/hash.orig"
for n in leaf1 leaf2 leaf3 leaf4; do dx $n sysctl -qw net.ipv4.fib_multipath_hash_policy=1; done

for h in h1 h3; do echo "$h $(nsx $h sysctl -n net.core.txrehash)"; done > "$ST/txrehash.orig"
for h in h1 h3; do nsx $h sysctl -qw net.core.txrehash=$REHASH; done
# 소켓은 만들어질 때 이 값을 가져간다. 듣고 있던 httpd 를 다시 띄워야 새 연결에 적용된다(첫 비교에서 놓친 부분)
dx h3 sh -c 'pkill -x httpd; httpd -p 80 -h /srv/www'
say "REHASH=$REHASH (서버 TCP 경로 재선택 $([ $REHASH = 1 ] && echo 켬 || echo 끔))"

# 프로브 (WSL 호스트에서 백그라운드)
( while [ ! -f "$ST/stop" ]; do
    r=$(dx h1 curl -s -o /dev/null --max-time 2 -r 0-1048575 -w '%{size_download}' http://172.16.13.10/big.bin)
    echo "$(date +%s.%N) $([ "${r:-0}" = 1048576 ] && echo 1 || echo 0)" >> "$ST/http"; sleep 0.5
  done ) &
( while [ ! -f "$ST/stop" ]; do
    dx h1 ping -c1 -W1 -q 172.16.13.10 >/dev/null 2>&1 && ok=1 || ok=0
    echo "$(date +%s.%N) $ok" >> "$ST/ping"; sleep 0.5
  done ) &

cap_start h1-eth1      h1     eth1 tcp port 80 or icmp
cap_start leaf3-eth1   leaf3  eth1 tcp port 80 or icmp
cap_start leaf3-eth2   leaf3  eth2 tcp port 80 or icmp
cap_start spine2-eth3  spine2 eth3 tcp port 80 or icmp
SNAP=0 cap_start leaf1-bgp leaf1 any tcp port 179
cap_wait 1

mark P0 "정상";                                   sleep 20
mark P1 "숨은 결함: spine2:eth3 MTU 9500 → 1500"
nsx spine2 ip link set eth3 mtu 1500;             sleep 30
mark P2 "spine1 조용한 먹통 (ip_forward=0 + docker pause)"
dx spine1 sysctl -qw net.ipv4.ip_forward=0; docker pause "$(c spine1)" >/dev/null; sleep 45
mark P3 "spine1 복구 (MTU 결함은 그대로)"
docker unpause "$(c spine1)" >/dev/null; dx spine1 sysctl -qw net.ipv4.ip_forward=1; sleep 30
mark P4 "MTU 복구"
nsx spine2 ip link set eth3 mtu 9500;             sleep 20
mark END "끝"

touch "$ST/stop"; sleep 3
cap_stop
while read -r n v; do dx $n sysctl -qw net.ipv4.fib_multipath_hash_policy="$v"; done < "$ST/hash.orig"
while read -r n v; do nsx $n sysctl -qw net.core.txrehash="$v"; done < "$ST/txrehash.orig"
dx h3 sh -c 'pkill -x httpd; httpd -p 80 -h /srv/www'

say "정리"
python3 "$HERE/report.py" "$ST" | tee "$CAPDIR/report.txt"
# Grafana 대시보드를 실험 구간으로 렌더
t0=$(awk '$1=="P0"{printf "%d", ($2-15)*1000}' "$ST/timeline"); t1=$(awk '$1=="END"{printf "%d", ($2+10)*1000}' "$ST/timeline")
mkdir -p "$HERE/img"
curl -s -m 120 "http://localhost:3000/render/d/clos-fabric/?width=1500&height=2300&theme=light&kiosk&from=$t0&to=$t1" -o "$HERE/img/grafana-rehash$REHASH.png"
W=$WINROOT/$(basename "$HERE")
cp "$CAPDIR/report.txt" "$ST/timeline" "$W/capture/rehash$REHASH/" 2>/dev/null
mkdir -p "$W/img" && cp "$HERE/img/grafana-rehash$REHASH.png" "$W/img/" 2>/dev/null
