#!/usr/bin/env bash
# 실험 21 — BGP Graceful Restart: 컨트롤 플레인이 재시작하는 동안 데이터 플레인.
# 소형 랩 grlab(스파인 2 + 리프 2 + 서버 2, ./up.sh 로 띄움) 에서 h1 → h2 ping(0.01초 간격)을 보며
#   A   GR 없음,        단일 경로(spine2 링크 내림)  spine1 bgpd kill -9  → watchfrr 가 다시 띄움
#   B1  GR 켬,          단일 경로                    같은 kill -9 (F 비트 0: preserve-fw-state 없음)
#   B2  GR + preserve-fw-state, 단일 경로             같은 kill -9 (F 비트 1)
#   B3  GR + preserve-fw-state + bgpd -K, 단일 경로   같은 kill -9 (재시작한 bgpd 가 재시작 모드). C 부터는 이 설정
#   C   GR 켬,          ECMP                         ping 이 타는 스파인 freeze (ip_forward=0 + docker pause)
#   D1  GR + BFD,       ECMP                         C 와 같은 freeze
#   D2  GR + BFD,       단일 경로                    B 와 같은 kill -9
#   D3  GR + BFD + check-control-plane-failure, 단일 경로, kill -9
#   D4  GR + BFD + check-control-plane-failure, ECMP, freeze
# GR = 네 라우터 모두 `bgp graceful-restart` + `restart-time 30` (기본 120초를 줄였다). BFD 는 기본 300ms × 3.
# 캡처: h1:eth1 (ICMP), leaf1·leaf2 의 대상 스파인 쪽 링크 (tcp 179, udp 3784)
# 사용: run.sh            전체 (capture/ 를 새로 만든다)
#       run.sh B D2       고른 Phase 만 (capture/ 에 덧붙인다)
set -u
export WINROOT=${WINROOT:-/mnt/c/Users/wsm02/Desktop/Claude/clos-fabric/experiments}
. "$(dirname "$0")/../../_tools/lab.sh"
. "$TOOLS/timeline.sh"
c() { echo "clab-grlab-$1"; }          # 이 랩의 노드 (lab.sh 의 clab-clos-* 를 덮어쓴다)
SNAP=128
DST=172.16.12.10
RT=30                                  # GR restart-time
ST=$HERE/state/run; mkdir -p "$ST"
if [ $# -eq 0 ]; then set -- A B1 B2 B3 C D1 D2 D3 D4; rm -rf "$CAPDIR"; mkdir -p "$CAPDIR"
  exec > >(tee "$CAPDIR/run-output.txt") 2>&1
else mkdir -p "$CAPDIR"; exec > >(tee -a "$CAPDIR/run-output.txt") 2>&1; fi

declare -A AS=([spine1]=65001 [spine2]=65002 [leaf1]=65011 [leaf2]=65012)
ROUTERS="spine1 spine2 leaf1 leaf2"
vt() { local n=$1; shift; local a=(); for x in "$@"; do a+=(-c "$x"); done; dx "$n" vtysh "${a[@]}"; }
bgpconf() { for n in $ROUTERS; do vt "$n" "conf t" "router bgp ${AS[$n]}" "$@" >/dev/null; done; }

# bgpd -K (재시작 모드로 기동): watchfrr 가 bgpd 를 다시 띄울 때 daemons 파일의 bgpd_options 를 읽는다
kopt() { local o='  -A 127.0.0.1'; [ "$1" = on ] && o='  -A 127.0.0.1 -K'
         for n in $ROUTERS; do dx "$n" sed -i "s/^bgpd_options=.*/bgpd_options=\"$o\"/" /etc/frr/daemons; done
         echo "  bgpd_options: $(dx spine1 grep ^bgpd_options /etc/frr/daemons)"; }
gr()   { case $1 in   # on = GR 만 (F 비트 0), fw = GR + preserve-fw-state (F 비트 1)
           on)  bgpconf "bgp graceful-restart" "bgp graceful-restart restart-time $RT" "no bgp graceful-restart preserve-fw-state" ;;
           fw)  bgpconf "bgp graceful-restart" "bgp graceful-restart restart-time $RT" "bgp graceful-restart preserve-fw-state" ;;
           fwk) gr fw ;;
           off) bgpconf "no bgp graceful-restart preserve-fw-state" "no bgp graceful-restart restart-time $RT" "no bgp graceful-restart" ;;
         esac; }
bfd()  { case $1 in
           on)  bgpconf "neighbor FABRIC bfd" ;;
           cpf) bgpconf "neighbor FABRIC bfd" "neighbor FABRIC bfd check-control-plane-failure" ;;
           off) bgpconf "no neighbor FABRIC bfd check-control-plane-failure" "no neighbor FABRIC bfd" ;;
         esac; }
# 단일 경로: 리프의 spine2 쪽 링크를 내린다 (대체 경로가 있으면 ECMP 가 GR 효과를 가린다)
single() { local s=down; [ "$1" = off ] && s=up; for l in leaf1 leaf2; do nsx "$l" ip link set eth2 $s; done; }
save()   { for n in $ROUTERS; do vt "$n" "write memory" >/dev/null; done; }   # watchfrr 가 다시 띄운 bgpd 가 읽을 설정
reset()  { for n in spine1 spine2; do vt "$n" "clear bgp *" >/dev/null; done; }  # 능력(GR) 협상을 새로 하게

up_peers() { dx "$1" vtysh -c "show bgp summary" | grep -cE '^spine[12]\(|^leaf[12]\(' | tr -d ' '; }
established() { dx "$1" vtysh -c "show bgp summary" | grep -E '^(spine|leaf)[12]\(' | grep -cE ' [0-9]+ +[0-9]+ +(spine|leaf)[12]$'; }
want=2
wait_sessions() {   # 리프 둘이 각각 $want 개 세션 Established + h1→h2 응답
  for _ in $(seq 90); do
    if [ "$(established leaf1)" = $want ] && [ "$(established leaf2)" = $want ] && dx h1 ping -c1 -W1 -q $DST >/dev/null 2>&1; then return 0; fi
    sleep 1; done
  echo "  (세션이 90초 안에 다 붙지 않았다)"; return 1
}
rxp() { dx "$1" cat "/sys/class/net/$2/statistics/rx_packets"; }
active() {   # h1→h2 요청이 지나는 스파인 번호 (leaf1 쪽 링크 eth1=spine1, eth2=spine2 의 스파인 수신 카운터)
  local a b c d; a=$(rxp spine1 eth1); b=$(rxp spine2 eth1)
  dx h1 ping -c 20 -i 0.01 -q $DST >/dev/null 2>&1
  c=$(rxp spine1 eth1); d=$(rxp spine2 eth1)
  [ $((c-a)) -ge $((d-b)) ] && echo 1 || echo 2
}
ractive() {  # 응답(h2→h1)이 지나는 스파인 번호 (spineN:eth2 = leaf2 쪽)
  local a b c d; a=$(rxp spine1 eth2); b=$(rxp spine2 eth2)
  dx h1 ping -c 20 -i 0.01 -q $DST >/dev/null 2>&1
  c=$(rxp spine1 eth2); d=$(rxp spine2 eth2)
  [ $((c-a)) -ge $((d-b)) ] && echo 1 || echo 2
}
bgpd_pid() { docker top "$(c "$1")" -eo pid,comm | awk '$2=="bgpd"{print $1}'; }

snap() {   # snap <라벨> <스파인>: leaf1 의 BGP 표·커널 경로, 스파인 커널 경로
  local s=$2
  echo "  --- [$1] leaf1 BGP 172.16.12.0/24 ---"
  vt leaf1 "show bgp ipv4 unicast 172.16.12.0/24" | grep -vE '^ *$|Advertised to|^ +[0-9.]+ [0-9.]+ *$' | sed 's/^/    /'
  echo "  --- [$1] leaf1 커널: $(nsx leaf1 ip route show 172.16.12.0/24 | tr '\n' ' ' | tr -s ' ')"
  echo "  --- [$1] $s 커널: $(nsx "$s" ip route show 172.16.12.0/24 | tr -s ' ') / $(nsx "$s" ip route show 172.16.11.0/24 | tr -s ' ')"
}
gr_info() {  # leaf1 이 본 상대 스파인의 GR 상태
  vt leaf1 "show bgp ipv4 neighbors $1 graceful-restart" | grep -E 'Local GR|Remote GR|R bit|N bit|Received Restart|F bit' | sed 's/^ *//' | paste -sd ';' | sed 's/;/; /g; s/^/    /'
}

# 시각 → T0 기준 초. 줄 앞의 시각(frr.log "2026/10/15 11:34:13.123" 은 UTC, ip -ts "[2026-10-15T20:34:13.123456]" 은 WSL 시간대)
rel() {   # [RELTZ=UTC] rel <T0> < 줄들
  local t0=$1 line ts
  while IFS= read -r line; do
    ts=$(echo "$line" | sed -nE 's#^\[?([0-9]{4})[/-]([0-9]{2})[/-]([0-9]{2})[T ]([0-9:.]+)\]?.*#\1-\2-\3 \4#p')
    [ -n "$ts" ] || continue
    printf '  T0%+7.3f  %s\n' "$(awk -v a="$(if [ -n "${RELTZ:-}" ]; then TZ=$RELTZ date -d "$ts" +%s.%N; else date -d "$ts" +%s.%N; fi)" -v b="$t0" 'BEGIN{print a-b}')" \
      "$(echo "$line" | sed -E 's#^\[?[0-9/-]+[T ][0-9:.]+\]? *##; s#^([A-Z]+): \[[A-Z0-9-]+\]#\1:#')"
  done
}
frrlog() {   # frrlog <노드> <T0> <from> <to> : 그 구간의 frr.log 중 GR·세션·BFD 관련
  local n=$1 t0=$2 a=$3 b=$4
  dx "$n" cat /tmp/frr.log 2>/dev/null | grep -E 'ADJCHANGE|graceful|Graceful|GR |stale|Stale|EOR|End-of-RIB|BFD|bfd|NOTIFICATION|Hold Timer|deferral|Deferral|restart' |
    grep -vE 'FD Limit|sending configuration|Peer flags updated' | RELTZ=UTC rel "$t0" | awk -v a="$a" -v b="$b" '{v=substr($1,3)+0} v>=a && v<=b' | head -${5:-40}
}

# 결과 정리
report() {   # report <tag> <T0> <spine> <from> <to>
  local tag=$1 T0=$2 s=$3 a=$4 b=$5
  say "Phase $tag 결과"
  echo "  응답 없는 요청: $(lost "$CAPDIR/$tag-h1-eth1.pcap") 개 (0.01초 간격)"
  echo "  $(reply_gap "$CAPDIR/$tag-h1-eth1.pcap" "$T0")"
  echo "  h2 에 닿은 요청이 끊긴 구간: $(tcpdump -tt -nn -r "$CAPDIR/$tag-h2-eth1.pcap" 'icmp[icmptype]==icmp-echo' 2>/dev/null | awk -v t0="$T0" 'NR>1{d=$1-p; if(d>m){m=d;s=p;e=$1}} {p=$1} END{printf "%.2f초 (T0%+.2f ~ T0%+.2f)", m, s-t0, e-t0}')"
  for l in leaf1 leaf2; do
    echo "  -- $l ↔ $s BGP·BFD (keepalive 제외, T0$a ~ T0+$b) --"
    bgp_events "$CAPDIR/$tag-$l-ctl.pcap" "$T0" "$a" "$b"
    echo "  -- $l ↔ $s TCP SYN/FIN/RST --"
    tcpdump -tt -nn -r "$CAPDIR/$tag-$l-ctl.pcap" 'tcp port 179 and (tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0)' 2>/dev/null |
      awk -v t0="$T0" '{printf "  T0%+7.3f  %s %s %s %s\n", $1-t0, $3, $4, $5, $7}' | head -12
    echo "  -- $l ↔ $s OPEN 의 GR 능력 / End-of-RIB / NOTIFICATION 세부 --"
    tcpdump -tt -nn -v -r "$CAPDIR/$tag-$l-ctl.pcap" 'tcp port 179' 2>/dev/null | awk -v t0="$T0" -v a="$a" -v b="$b" '
      /^[0-9]+\.[0-9]+ / { ts=$1; next }
      /^ +[0-9.]+ > [0-9.]+:/ { split($0,x," "); sd=x[1] " > " x[3]; sub(":$","",sd) }
      { r=ts-t0; if (r<a||r>b) next }
      /Restart Flags|Restart Time|AFI IPv4|End-of-Rib|Error code|error subcode|Cease|Hard Reset/ {
        m=$0; sub(/^[ \t]+/,"",m); printf "  T0%+7.3f  %-26s %s\n", r, sd, m }' | uniq | head -30
  done
  for n in leaf1 "$s"; do
    echo "  -- $n 커널 경로 변화 (172.16.11/12.0/24) --"
    grep -E '172\.16\.1[12]\.0/24' "$CAPDIR/$tag-$n-route.txt" 2>/dev/null | rel "$T0" | head -12
  done
  echo "  -- leaf1 frr.log --"; frrlog leaf1 "$T0" "$a" "$b"
  echo "  -- $s frr.log --";    frrlog "$s" "$T0" "$a" "$b"
}

caps() {   # caps <tag> <spine 번호> : ping 양 끝, 리프 둘의 그 스파인 쪽 컨트롤 플레인, 커널 경로 변화
  local s=spine$2
  cap_start "$1-h1-eth1"   h1    eth1 icmp
  cap_start "$1-h2-eth1"   h2    eth1 icmp
  SNAP=0 cap_start "$1-leaf1-ctl" leaf1 "eth$2" tcp port 179 or udp port 3784
  SNAP=0 cap_start "$1-leaf2-ctl" leaf2 "eth$2" tcp port 179 or udp port 3784
  for n in leaf1 "$s"; do
    nsenter -t "$(pid "$n")" -n ip -ts monitor route > "$CAPDIR/$1-$n-route.txt" 2>&1 &
    echo $! >> "$CAPDIR/.pids"
  done
  cap_wait 1
}

# Phase 종류 1: bgpd 만 죽는다 (컨트롤 플레인 재시작). 데이터 플레인(커널 FIB)은 그대로
phase_kill() {   # phase_kill <tag> <설명>
  local tag=$1 T0 P
  say "Phase $tag — $2"
  echo "  leaf1 → spine1 GR 상태:"; gr_info 10.1.1.0
  vt leaf1 "show bfd peers brief" | grep -E ' up | down ' | sed 's/^/  BFD /'
  caps "$tag" 1
  docker exec -d "$(c h1)" sh -c "ping -i 0.01 -w 33 $DST > /tmp/ping21.txt 2>&1"
  sleep 3
  P=$(bgpd_pid spine1)
  T0=$(now); kill -9 "$P"
  echo "$T0" > "$CAPDIR/$tag.T0"
  say "T0 spine1 bgpd kill -9 (pid $P)"
  sleep 1.5; snap "T0+1.5" spine1
  for _ in $(seq 100); do [ -n "$(bgpd_pid spine1)" ] && break; sleep 0.1; done
  echo "  새 bgpd 확인: T0+$(awk -v t="$T0" -v n="$(now)" 'BEGIN{printf "%.1f", n-t}') (pid $(bgpd_pid spine1))"
  sleep 3; snap "새 bgpd 직후" spine1
  sleep 26
  cap_stop
  report "$tag" "$T0" spine1 -1 30
  say "세션 재수립 대기"; wait_sessions; echo "  leaf1 Established $(established leaf1)/$want"
}

# Phase 종류 2: 장비 통째 먹통 (07 과 같은 freeze). 컨트롤·데이터 플레인 둘 다 죽고 링크는 up
phase_freeze() {   # phase_freeze <tag> <설명> <관찰 초>
  local tag=$1 dur=$3 A R S P T0
  say "Phase $tag — $2"
  A=$(active); R=$(ractive); S=spine$A
  echo "  요청 h1→h2: leaf1 → spine$A   응답 h2→h1: leaf2 → spine$R   얼릴 장비: $S"
  echo "  leaf1 → $S GR 상태:"; gr_info "10.1.$A.0"
  vt leaf1 "show bfd peers brief" | grep -E ' up | down ' | sed 's/^/  BFD /'
  caps "$tag" "$A"
  docker exec -d "$(c h1)" sh -c "ping -i 0.01 -w $((dur + 8)) $DST > /tmp/ping21.txt 2>&1"
  sleep 3
  P=$(pid "$S"); [ -n "$P" ] || { echo "pid 없음"; return 1; }
  T0=$(now); nsenter -t "$P" -n sysctl -qw net.ipv4.ip_forward=0; docker pause "$(c "$S")" >/dev/null
  echo "$T0" > "$CAPDIR/$tag.T0"
  say "T0 $S 먹통 (ip_forward=0 + docker pause, 링크는 up)"
  sleep 12; snap "T0+12" "$S"
  echo "  leaf1 → $S:"; vt leaf1 "show bgp neighbors 10.1.$A.0" | grep -E 'BGP state|restart timer|Graceful restart|stale|Last reset|Stale' | sed 's/^ */    /' | head -8
  sleep $((dur - 12)); snap "T0+$dur" "$S"
  docker unpause "$(c "$S")" >/dev/null; nsenter -t "$P" -n sysctl -qw net.ipv4.ip_forward=1
  say "T0+$dur $S 복구"
  sleep 6
  cap_stop
  report "$tag" "$T0" "$S" -1 "$dur"
  say "세션 재수립 대기"; wait_sessions; echo "  leaf1 Established $(established leaf1)/$want"
}

# Phase 마다 랩을 새로 띄운다. 같은 zebra 에서 bgpd 재시작을 몇 분 안에 되풀이하면
# 앞 재시작의 GR 흔적(zebra 의 stale 경로 정리)이 다음 Phase 에 섞이는 것을 첫 실행에서 봤다
fresh() { say "랩 새로 띄우기 (down.sh → up.sh)"; "$HERE/down.sh" >/dev/null 2>&1; "$HERE/up.sh" >/dev/null 2>&1; FRESH_T=$(date +%s); sleep 10
          echo "  $(docker ps --format '{{.Names}}' | grep -c '^clab-grlab-') 노드 기동"; }

setup() {   # setup <gr on|off> <bfd on|cpf|off> <single on|off>
  [ "${FRESH:-1}" = 1 ] && fresh
  say "설정: GR $1 / BFD $2 / 단일경로 $3"
  for n in $ROUTERS; do vt "$n" "conf t" "log file /tmp/frr.log" "log timestamp precision 3"     "debug bgp neighbor-events" "debug bgp graceful-restart" "debug bgp bfd" >/dev/null; done
  gr "$1"; bfd "$2"; single "$3"; save; reset
  if [ "$1" = fwk ]; then kopt on; else kopt off; fi
  if [ "$3" = on ]; then want=1; else want=2; fi
  sleep 3; wait_sessions; sleep 3
  # 막 기동한 bgpd 는 기동 후 일정 시간(기동 때의 restart-time, 기본 120초) OPEN 에 R 비트를 세운다.
  # 리프가 R 비트를 세운 채면 재시작한 스파인이 리프의 End-of-RIB 을 기다리지 않는다(첫 실행에서 봤다).
  # 운영 중인 패브릭처럼 리프가 기동 후 충분히 지난 상태에서 장애를 넣으려고, 기동 뒤 130초까지 기다린다
  local w=$(( 130 - ($(date +%s) - ${FRESH_T:-0}) ))
  if [ $w -gt 0 ]; then echo "  리프 bgpd 기동 후 130초가 되도록 ${w}초 대기"; sleep $w; fi
  echo "  leaf1 Established $(established leaf1)/$want, leaf2 $(established leaf2)/$want"
}

say "기준값"
docker exec "$(c spine1)" vtysh -c "show version" | head -1
nsx leaf1 ip route show 172.16.12.0/24

for ph in "$@"; do case $ph in
  A)  setup off off on;  phase_kill A  "GR 없음, 단일 경로, spine1 bgpd kill -9" ;;
  B1) setup on  off on;  phase_kill B1 "GR (F 비트 0), 단일 경로, spine1 bgpd kill -9" ;;
  B2) setup fw  off on;  phase_kill B2 "GR + preserve-fw-state (F 비트 1), 단일 경로, spine1 bgpd kill -9" ;;
  B3) setup fwk off on;  phase_kill B3 "GR + preserve-fw-state + bgpd -K, 단일 경로, spine1 bgpd kill -9" ;;
  C)  setup fwk off off; phase_freeze C  "GR, ECMP, 스파인 freeze" 48 ;;
  D1) setup fwk on  off; phase_freeze D1 "GR + BFD, ECMP, 스파인 freeze" 15 ;;
  D2) setup fwk on  on;  phase_kill D2 "GR + BFD, 단일 경로, spine1 bgpd kill -9" ;;
  D3) setup fwk cpf on;  phase_kill D3 "GR + BFD + check-control-plane-failure, 단일 경로, kill -9" ;;
  D4) setup fwk cpf off; phase_freeze D4 "GR + BFD + check-control-plane-failure, ECMP, freeze" 15 ;;
esac; done

say "원복 — GR·BFD 끄고 링크 올림 (랩은 그대로 둔다. 지울 때는 down.sh)"
FRESH=0 setup off off off
