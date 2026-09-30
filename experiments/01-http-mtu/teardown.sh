#!/usr/bin/env bash
# 실험 전 상태로 되돌린다: 장애 복구 → 캡처 중지 → httpd 중지 → MTU/해시정책 원복.
# 테스트 파일(/srv)은 기본으로 남긴다. 지우려면: PURGE=1 ./teardown.sh
set -u
. "$(dirname "$0")/lib.sh"
H=$(dirname "$0")
"$H/fault.sh" restore >/dev/null
"$H/cap.sh" stop >/dev/null 2>&1
for h in $CLIENT $SERVER; do docker exec "$(c $h)" pkill -x httpd 2>/dev/null; done
if [ -f "$STATE/mtu.orig" ]; then
  # 브리지는 포트를 따라가므로 호스트/포트 먼저, 브리지 나중 (파일 순서를 뒤집어 적용)
  tac "$STATE/mtu.orig" | while read -r p m; do set_mtu "$p" "$m"; done
  while read -r n v; do docker exec "$(c $n)" sysctl -qw net.ipv4.fib_multipath_hash_policy="$v"; done < "$STATE/hash.orig"
  rm -f "$STATE/mtu.orig" "$STATE/hash.orig"
  echo "MTU·해시정책 원복"
fi
[ "${PURGE:-0}" = 1 ] && docker exec "$(c $SERVER)" rm -rf /srv && echo "/srv 삭제"
# 검증: 원래 값과 다른 게 남았는지
for p in leaf1:eth1 spine1:eth3 leaf1:vni10010 leaf1:br10010 v1:eth1; do echo "  $p mtu $(mtu_of "$p")"; done
echo "  leaf1 hash=$(docker exec "$(c leaf1)" sysctl -n net.ipv4.fib_multipath_hash_policy)"
docker exec "$(c $CLIENT)" ping -c2 -W1 -q $SERVER_IP | tail -1
