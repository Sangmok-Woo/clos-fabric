#!/usr/bin/env bash
# 3단계: BGP 세션에 BFD를 붙인다. (해제하려면 ./scripts/bfd-apply.sh off)
set -u
OFF=${1:-on}
for n in spine1 spine2 leaf1 leaf2 leaf3 leaf4; do
  as=$(docker exec clab-clos-$n vtysh -c "show run" 2>/dev/null | awk '/^router bgp/{print $3; exit}')
  if [ "$OFF" = "off" ]; then
    docker exec clab-clos-$n vtysh -c "conf t" -c "router bgp $as" -c "no neighbor FABRIC bfd" >/dev/null 2>&1
  else
    # 300ms 간격, 3번 놓치면 죽은 것으로 본다 → 1초 이내 감지
    docker exec clab-clos-$n vtysh -c "conf t" -c "router bgp $as" \
      -c "neighbor FABRIC bfd" -c "neighbor FABRIC bfd 3 300 300" >/dev/null 2>&1
  fi
  echo "  $n (AS $as) : bfd $OFF"
done
sleep 3
echo
docker exec clab-clos-leaf1 vtysh -c "show bfd peers brief" 2>/dev/null
