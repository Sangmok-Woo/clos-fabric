#!/usr/bin/env bash
# ECMP가 실제로 두 스파인으로 나눠 보내는지, 해시 정책을 바꿔가며 센다.
# 사용법: ./scripts/ecmp-hash.sh
set -u
FLOWS=${FLOWS:-40}

# h1 -> h4 로 "목적지 포트만 다른" UDP 흐름을 동시에 여러 개 던진다.
PORTS=$(seq 5000 $((5000 + FLOWS - 1)) | tr '\n' ' ')
gen() {
  docker exec clab-clos-h1 sh -c "for p in $PORTS; do (echo x | nc -u -w1 172.16.14.10 \$p >/dev/null 2>&1) & done; wait" >/dev/null 2>&1
}
cnt() { docker exec clab-clos-leaf1 cat /sys/class/net/$1/statistics/tx_packets; }

measure() {
  b1=$(cnt eth1); b2=$(cnt eth2)
  gen
  a1=$(cnt eth1); a2=$(cnt eth2)
  echo "   eth1(→spine1) +$((a1-b1))    eth2(→spine2) +$((a2-b2))"
}

for pol in 0 1; do
  docker exec clab-clos-leaf1 sysctl -w net.ipv4.fib_multipath_hash_policy=$pol >/dev/null
  case $pol in
    0) echo "[해시 정책 0] 출발지·목적지 IP만 보고 경로를 고른다 — 흐름 $FLOWS 개:";;
    1) echo "[해시 정책 1] 포트(L4)까지 보고 고른다 — 흐름 $FLOWS 개:";;
  esac
  measure
done
echo
echo "* 정책 0에서는 h1→h4 라는 IP 쌍이 하나라서 모든 흐름이 한 쪽 링크로만 간다."
echo "* 정책 1로 바꾸면 포트가 다르므로 두 링크에 갈린다. 운영에서는 리프에 반드시 1로 박아둔다."
