#!/usr/bin/env bash
# 장애를 주입하고 "몇 초 끊겼는지"를 잃어버린 핑 개수로 잰다.
# 사용법: ./scripts/failover.sh link    # 케이블 뽑기 (링크 다운 = 즉시 감지)
#         ./scripts/failover.sh freeze  # 스파인 먹통 (링크는 살아 있는 조용한 장애)
#
# 주의: ECMP라서 h1→h4 핑이 어느 스파인을 타는지 매번 다르다.
#       그래서 먼저 "지금 이 핑이 타는 스파인"을 찾아내고 그 쪽을 죽인다.
set -u
MODE=${1:-link}
IVL=0.2          # 핑 간격(초). 잃은 개수 × 0.2 ≈ 끊긴 시간
COUNT=100        # 총 20초
TGT=172.16.14.10

cnt() { docker exec clab-clos-leaf1 cat /sys/class/net/$1/statistics/tx_packets; }

echo "[*] 지금 h1→h4 핑이 어느 스파인을 타는지 확인"
b1=$(cnt eth1); b2=$(cnt eth2)
docker exec clab-clos-h1 ping -c 5 -i 0.2 -W 1 $TGT >/dev/null 2>&1
a1=$(cnt eth1); a2=$(cnt eth2)
if [ $((a1-b1)) -ge $((a2-b2)) ]; then ACT=1; else ACT=2; fi
echo "    → spine$ACT 경유 (eth1 +$((a1-b1)) / eth2 +$((a2-b2)))"

echo "[*] 핑 시작 (${IVL}초 간격, 총 $(awk "BEGIN{print $COUNT*$IVL}")초)"
docker exec -d clab-clos-h1 sh -c "ping -i $IVL -c $COUNT $TGT > /tmp/ping.txt 2>&1"
sleep 4

case "$MODE" in
  link)
    echo "[*] t=4s  leaf1 eth$ACT (→spine$ACT) 링크 다운 — 케이블을 뽑은 상황"
    docker exec clab-clos-leaf1 ip link set eth$ACT down
    ;;
  freeze)
    echo "[*] t=4s  spine$ACT 먹통 — 포워딩을 끄고(=패킷을 버림) 프로세스를 얼린다(=BGP가 조용히 멎는다)"
    docker exec clab-clos-spine$ACT sysctl -w net.ipv4.ip_forward=0 >/dev/null
    docker pause clab-clos-spine$ACT >/dev/null
    ;;
esac

sleep 18
echo "[*] 복구"
case "$MODE" in
  link)   docker exec clab-clos-leaf1 ip link set eth$ACT up ;;
  freeze) docker unpause clab-clos-spine$ACT >/dev/null
          docker exec clab-clos-spine$ACT sysctl -w net.ipv4.ip_forward=1 >/dev/null ;;
esac

echo
docker exec clab-clos-h1 tail -3 /tmp/ping.txt
RCV=$(docker exec clab-clos-h1 sh -c "grep -o '[0-9]* packets received' /tmp/ping.txt | head -1" | awk '{print $1}')
SENT=$(docker exec clab-clos-h1 sh -c "grep -o '^[0-9]* packets transmitted' /tmp/ping.txt | head -1" | awk '{print $1}')
if [ -n "${SENT:-}" ] && [ -n "${RCV:-}" ]; then
  D=$(( SENT - RCV ))
  echo "[=] 잃은 패킷 ${D}개 → 약 $(awk "BEGIN{print $D*$IVL}")초 끊김"
fi
sleep 12
echo "[*] 복구 후 leaf1 세션"
docker exec clab-clos-leaf1 vtysh -c "show ip bgp summary" 2>/dev/null | grep -E "spine[12]"
