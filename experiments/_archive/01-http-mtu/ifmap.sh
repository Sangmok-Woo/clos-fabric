#!/usr/bin/env bash
# 캡처 지점 인터페이스 맵. 각 지점이 어디로 이어지는지, MTU, 주소를 표로 찍는다.
set -u
. "$(dirname "$0")/lib.sh"
printf "| %-12s | %-18s | %-5s | %-16s |\n" 지점 상대편 MTU 주소
printf "|%s|%s|%s|%s|\n" -------------- -------------------- ------- ------------------
peer_of() {  # clos.clab.yml 의 링크 정의에서 상대편을 찾는다
  grep -o "\"[a-z0-9]*:eth[0-9]*\", *\"[a-z0-9]*:eth[0-9]*\"" "$HERE/../../clos.clab.yml" | tr -d '" ' |
    awk -F, -v me="$1" '$1==me{print $2} $2==me{print $1}'
}
for p in $CAP_POINTS; do
  n=${p%%:*}; i=${p##*:}
  a=$(docker exec "$(c "$n")" ip -4 -o addr show "$i" | awk '{print $4}')
  printf "| %-12s | %-18s | %-5s | %-16s |\n" "$p" "$(peer_of "$p")" "$(mtu_of "$p")" "${a:--}"
done
echo
echo "오버레이: $(for p in $OVERLAY_IFS; do printf '%s=%s ' "$p" "$(mtu_of "$p")"; done)"
echo "해시정책: $(for n in leaf1 leaf3; do printf '%s=%s ' $n "$(docker exec "$(c $n)" sysctl -n net.ipv4.fib_multipath_hash_policy)"; done)"
echo "VTEP: leaf1=10.255.1.1  leaf3=10.255.1.3   클라이언트 $CLIENT $CLIENT_IP / 서버 $SERVER $SERVER_IP:$PORT"
