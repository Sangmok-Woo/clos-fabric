#!/usr/bin/env bash
# 명령 하나를 실행하는 동안 리프 업링크 카운터가 얼마나 늘었는지 보여준다.
# "이 플로우가 어느 스파인을 탔나"를 캡처 없이 빠르게 확인하는 용도.
#   leaf1 eth1/eth2 tx = v1 -> v3 방향이 탄 스파인
#   leaf3 eth1/eth2 tx = v3 -> v1 방향(다운로드 데이터)이 탄 스파인
# 사용법: ./via.sh <명령...>
#   FLUSH=1 ./via.sh ...   실행 전에 leaf1/leaf3 route cache 를 비운다.
#   리눅스 VXLAN은 원격 VTEP별로 경로를 캐시해서, 안 비우면 모든 플로우가 같은 스파인을 탄다.
#   ./via.sh docker exec clab-clos-v1 ping -c3 -s 1423 -M do 10.10.10.33
set -u
. "$(dirname "$0")/lib.sh"
snap() {
  for p in leaf1:eth1 leaf1:eth2 leaf3:eth1 leaf3:eth2; do
    docker exec "$(c "${p%%:*}")" cat "/sys/class/net/${p##*:}/statistics/tx_packets"
  done | tr '\n' ' '
}
[ "${FLUSH:-0}" = 1 ] && for n in leaf1 leaf3; do docker exec "$(c $n)" ip route flush cache; done
read -r a b c d <<< "$(snap)"
"$@"; rc=$?
read -r A B C D <<< "$(snap)"
echo "---- 업링크 tx 증가량"
echo "  leaf1 -> spine1 +$((A-a))   leaf1 -> spine2 +$((B-b))    (v1->v3 방향)"
echo "  leaf3 -> spine1 +$((C-c))   leaf3 -> spine2 +$((D-d))    (v3->v1 방향)"
exit $rc
