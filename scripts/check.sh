#!/usr/bin/env bash
# 패브릭 상태 한 번에 보기.  사용법: ./scripts/check.sh
set -u
S="spine1 spine2"
L="leaf1 leaf2 leaf3 leaf4"
v() { docker exec clab-clos-$1 vtysh -c "$2" 2>/dev/null; }

echo "=== 1) BGP 세션 (established 개수 / 기대치) ==="
for n in $S; do
  c=$(v $n "show ip bgp summary json" | grep -o '"state":"Established"' | wc -l)
  echo "  $n : $c / 4"
done
for n in $L; do
  c=$(v $n "show ip bgp summary json" | grep -o '"state":"Established"' | wc -l)
  echo "  $n : $c / 2"
done

echo
echo "=== 2) ECMP (leaf1 → 다른 랙 서버망, 넥스트홉 2개여야 정상) ==="
for p in 172.16.12.0/24 172.16.13.0/24 172.16.14.0/24; do
  n=$(docker exec clab-clos-leaf1 ip route show $p | grep -c nexthop)
  [ "$n" = "0" ] && n=$(docker exec clab-clos-leaf1 ip route show $p | grep -c via)
  echo "  $p : nexthop $n"
done

echo
echo "=== 3) 서버 간 통신 (h1 → h2/h3/h4) ==="
for t in 172.16.12.10 172.16.13.10 172.16.14.10; do
  if docker exec clab-clos-h1 ping -c1 -W1 $t >/dev/null 2>&1; then
    echo "  h1 -> $t : OK"
  else
    echo "  h1 -> $t : FAIL"
  fi
done

echo
echo "=== 4) BFD 세션 (3단계 BFD 적용 전이면 비어 있는 게 정상) ==="
docker exec clab-clos-leaf1 vtysh -c "show bfd peers brief" 2>/dev/null | tail -n +1
