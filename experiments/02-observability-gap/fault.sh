#!/usr/bin/env bash
# MTU 장애 주입/복구. 스파인 한 대의 리프3(수신 리프) 방향 인터페이스만 1500으로 낮춘다.
# 리프 쪽은 건드리지 않는다 — 리프는 계속 큰 프레임을 보내야 한다.
#
# 사용법:
#   ./fault.sh inject [spine1|spine2]   (기본 spine1)
#   ./fault.sh restore
#   ./fault.sh status                   MTU + 드랍 카운터 (양쪽 끝 모두)
set -eu
. "$(dirname "$0")/lib.sh"
IF=eth3    # 스파인 eth3 = leaf3 방향
mkdir -p "$STATE"

show() {
  for p in spine1:eth3 spine2:eth3 leaf3:eth1 leaf3:eth2; do
    n=${p%%:*}; i=${p##*:}
    echo "--- $p  (mtu $(mtu_of "$p"))"
    docker exec "$(c "$n")" ip -s link show "$i" | sed -n '3,6p'
  done
}

case "${1:-status}" in
  inject)
    S=${2:-spine1}
    [ -f "$STATE/fault" ] && { echo "이미 주입됨: $(cat "$STATE/fault"). restore 먼저"; exit 1; }
    echo "$S:$IF $(mtu_of "$S:$IF")" > "$STATE/fault"
    echo "=== 주입 직전 스냅샷 ==="; show > "$STATE/fault-before.txt"; cat "$STATE/fault-before.txt"
    set_mtu "$S:$IF" 1500
    echo; echo ">>> $S:$IF mtu 1500 주입 (원래 값은 state/fault)" ;;
  restore)
    [ -f "$STATE/fault" ] || { echo "주입된 장애 없음"; exit 0; }
    read -r P M < "$STATE/fault"
    set_mtu "$P" "$M"; rm -f "$STATE/fault"
    echo ">>> $P mtu $M 복구"; show ;;
  status) [ -f "$STATE/fault" ] && echo "장애 주입 중: $(cat "$STATE/fault")" || echo "장애 없음"; show ;;
  *) sed -n 2,8p "$0" ;;
esac
