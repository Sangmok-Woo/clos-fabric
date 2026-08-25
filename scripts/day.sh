#!/usr/bin/env bash
# 하루 5분 Clos 실습 진행기.
#
#   ./scripts/day.sh            오늘 문제를 내고 고장을 걸어둔다  (예측 -> 직접 확인)
#   ./scripts/day.sh 답          정답을 보여주고 원상복구 + 진도 +1
#   ./scripts/day.sh 12         12일차로 건너뛴다
#   ./scripts/day.sh 목록        30일 전체 목록
#   ./scripts/day.sh 상태        지금 며칠차인지, 고장이 걸려 있는지
#   ./scripts/day.sh 복구        정답 안 보고 그냥 원상복구
#   ./scripts/day.sh 재배포      랩을 통째로 다시 세운다 (WSL 재시작 후 필요)
#
# 영어 별칭:  ask(기본) / answer,done / list / status / restore / redeploy
set -u

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LAB_DIR"
STATE="$LAB_DIR/.day-state"
LOG="$LAB_DIR/docs/41-하루5분-기록.md"

# ── 헬퍼 (days.sh 안에서 쓴다) ───────────────────────────────────────────────
X(){ local n=$1; shift; docker exec "clab-clos-$n" "$@" 2>/dev/null; }
V(){ local n=$1; shift; docker exec "clab-clos-$n" vtysh -c "$1" 2>/dev/null; }
C(){ local n=$1; shift; local a=() l
     for l in "$@"; do a+=(-c "$l"); done
     docker exec "clab-clos-$n" vtysh -c "configure terminal" "${a[@]}" >/dev/null 2>&1; }
# NS: 호스트의 도구를 해당 노드의 네트워크 네임스페이스 안에서 실행한다.
# alpine 서버들의 busybox ping/ip 로는 -M do 나 neigh replace 를 못 하기 때문에 필요하다.
NS(){ local n=$1; shift; local pid
      pid=$(docker inspect -f '{{.State.Pid}}' "clab-clos-$n" 2>/dev/null) || return 1
      nsenter -t "$pid" -n "$@"; }
TD(){ local n=$1; shift; local pid
      pid=$(docker inspect -f '{{.State.Pid}}' "clab-clos-$n" 2>/dev/null) || return 1
      timeout 15 nsenter -t "$pid" -n tcpdump "$@"; }
# FRR 로그: bgpd 는 watchfrr 밑에서 따로 돌아서 docker logs 에 안 찍힌다.
# 그래서 컨테이너 안 파일로 남기고 그걸 읽는다 (logsetup 이 켜준다).
FRRLOG(){ docker exec "clab-clos-$1" sh -c "tail -${2:-15} /tmp/frr.log" 2>/dev/null; }
HR(){ echo; echo "── $* ──"; }

source "$LAB_DIR/scripts/days.sh"

# ── 상태 ────────────────────────────────────────────────────────────────────
DAY=1; ARMED=0
[ -f "$STATE" ] && . "$STATE"
save(){ printf 'DAY=%s\nARMED=%s\n' "$DAY" "$ARMED" > "$STATE"; }
pad(){ printf '%02d' "$1"; }
call(){ local f="d$(pad "$1")_$2"; declare -F "$f" >/dev/null && "$f"; }

# ── WSL 배포판 붙잡아 두기 ──────────────────────────────────────────────────
# WSL 은 안에 프로세스가 하나도 없으면 배포판을 통째로 종료한다.
# 그러면 dockerd 가 재시작되면서 containerlab 이 만든 veth 가 전부 사라진다
# (컨테이너는 살아 있는데 eth1 이 없는 상태). 그래서 잠자는 프로세스를 하나 남겨둔다.
keepalive(){
  pgrep -f 'clos-keepalive' >/dev/null 2>&1 && return
  setsid bash -c 'exec -a clos-keepalive sleep infinity' >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# FRR 이 로그를 파일로 남기게 한다 (한 번만 하면 된다. 재배포하면 다시 해야 한다)
logsetup(){
  local n
  for n in spine1 spine2 leaf1 leaf2 leaf3 leaf4; do
    docker exec "clab-clos-$n" sh -c '[ -f /tmp/frr.log ]' 2>/dev/null && continue
    docker exec "clab-clos-$n" vtysh -c "configure terminal" \
      -c "log file /tmp/frr.log informational" >/dev/null 2>&1
  done
}

# ── 랩이 살아 있는지 먼저 본다 ───────────────────────────────────────────────
preflight(){
  keepalive
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^clab-clos-leaf1$'; then
    echo "!! 랩이 안 떠 있다.  ./scripts/day.sh 재배포  를 먼저 실행하자."; exit 1
  fi
  if ! docker exec clab-clos-leaf1 ip link show eth1 >/dev/null 2>&1; then
    cat <<'EOF'
!! 컨테이너는 떠 있는데 패브릭 링크(eth1)가 없다.
   WSL 을 껐다 켜면 veth 가 전부 사라지기 때문이다. 아래를 실행하고 다시 오자.

     ./scripts/day.sh 재배포
EOF
    exit 1
  fi
  logsetup
}

banner(){
  local _dn=$1
  echo "════════════════════════════════════════════════════════════"
  echo "  Day $(pad "$_dn") / $TOTAL_DAYS   —   $(call "$_dn" title)"
  echo "════════════════════════════════════════════════════════════"
}

do_ask(){
  preflight
  local _dn=$1
  if [ "$ARMED" = "1" ]; then
    echo "(이미 Day $(pad "$_dn") 고장이 걸려 있다. 문제를 다시 보여준다.)"
    banner "$_dn"; call "$_dn" ask
    echo; echo "─ 확인해볼 명령 ─"; call "$_dn" check
    echo; echo "다 봤으면:  ./scripts/day.sh 답"
    return
  fi
  banner "$_dn"
  call "$_dn" ask
  echo
  echo "... 고장 주입 중"
  call "$_dn" inject
  echo "완료."
  echo
  echo "─ 확인해볼 명령 (먼저 답을 예측하고 나서 쳐보자) ─"
  call "$_dn" check
  echo
  echo "다 봤으면:  ./scripts/day.sh 답"
  ARMED=1; save
}

do_answer(){
  preflight
  local _dn=$1
  banner "$_dn"
  call "$_dn" answer
  echo
  echo "... 원상복구 중"
  call "$_dn" restore
  sleep 2
  echo "완료."
  log_day "$_dn"
  if [ "$_dn" -lt "$TOTAL_DAYS" ]; then
    DAY=$((_dn+1)); ARMED=0; save
    echo; echo "내일은 Day $(pad "$DAY") — $(call "$DAY" title)"
  else
    ARMED=0; save
    echo; echo "30일 완주. 기록은 $LOG 에 있다."
  fi
}

log_day(){
  local _dn=$1
  mkdir -p "$(dirname "$LOG")"
  if [ ! -f "$LOG" ]; then
    cat > "$LOG" <<'EOF'
# 하루 5분 — 기록

예측이 맞았는지만 채워 넣으면 된다. 빗나간 날이 곧 다음에 볼 곳이다.

| 일차 | 날짜 | 제목 | 예측 맞음? | 메모 |
|---|---|---|---|---|
EOF
  fi
  printf '| %s | %s | %s |  |  |\n' "$(pad "$_dn")" "$(date +%Y-%m-%d)" "$(call "$_dn" title)" >> "$LOG"
}

do_list(){
  echo "── 하루 5분 · 30일 ──"
  local i
  for i in $(seq 1 "$TOTAL_DAYS"); do
    local mark="  "
    [ "$i" -lt "$DAY" ] && mark="✓ "
    [ "$i" = "$DAY" ] && mark="▶ "
    case $i in
      1) echo "  [1주차 · 물리와 링크]" ;;
      7) echo "  [2주차 · BGP 설정]" ;;
      14) echo "  [3주차 · 포워딩과 커널]" ;;
      21) echo "  [4주차 · 눈으로 보기]" ;;
      27) echo "  [5주차 · 종합]" ;;
    esac
    printf '  %s%s  %s\n' "$mark" "$(pad "$i")" "$(call "$i" title)"
  done
}

case "${1:-ask}" in
  ask|"")            do_ask "$DAY" ;;
  답|answer|done|a)   do_answer "$DAY" ;;
  목록|list|l)        do_list ;;
  상태|status|s)
      echo "현재: Day $(pad "$DAY") — $(call "$DAY" title)"
      [ "$ARMED" = "1" ] && echo "상태: 고장이 걸려 있다 (./scripts/day.sh 답 으로 복구)" \
                         || echo "상태: 정상 (./scripts/day.sh 로 오늘 문제 시작)"
      ;;
  복구|restore|r)
      preflight; echo "Day $(pad "$DAY") 복구 중..."; call "$DAY" restore; sleep 2
      ARMED=0; save; echo "완료."; bash "$LAB_DIR/scripts/check.sh" ;;
  재배포|redeploy)
      keepalive
      echo "랩을 다시 세운다 (1~2분)..."
      bash "$LAB_DIR/scripts/deploy.sh" redeploy >/dev/null 2>&1
      sleep 12; ARMED=0; save; logsetup
      bash "$LAB_DIR/scripts/check.sh" ;;
  [0-9]*)
      if [ "$1" -ge 1 ] && [ "$1" -le "$TOTAL_DAYS" ]; then
        if [ "$ARMED" = "1" ]; then
          echo "Day $(pad "$DAY") 고장이 아직 걸려 있다. 먼저 복구한다..."
          call "$DAY" restore; sleep 2
        fi
        DAY=$1; ARMED=0; save; do_ask "$DAY"
      else
        echo "1 ~ $TOTAL_DAYS 사이의 숫자를 넣자."; exit 1
      fi ;;
  *) sed -n '2,16p' "$0" ;;
esac
