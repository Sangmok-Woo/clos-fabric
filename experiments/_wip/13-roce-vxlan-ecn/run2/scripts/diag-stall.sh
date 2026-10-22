#!/usr/bin/env bash
# 장애1(디캡 CE 누락)의 '전면 정지' 원인 좁히기 — 1회차 README 의 "설명 못 한 것" 후속.
#   정지 구간에 큐는 비었는데 병목 RED 드랍이 초당 몇 개씩 남는다. 무엇이, 왜 버려지는가.
#   1) spine1:eth3 RED xstats(marked/early/pdrop/other)와 큐 바이트를 0.2초마다
#   2) 병목 앞(leaf1:eth1)과 뒤(leaf3:eth1)에서 '바깥 ECN 이 Not-ECT 인 VXLAN'만 캡처 (작다)
#   3) g1(xg1)에서 TCP 를 앞 96B 만 (재전송·RTO·ACK 확인용)
#   4) g1 → g3 ECT ping (-Q 2) 50ms 간격
#   5) spine1–leaf3 BGP 세션이 끊긴 횟수 (connectionsDropped 앞뒤)
#   diag-stall.sh [초=40]              — setup.sh 다음, 다른 측정이 없을 때
#   PROTECT=1 diag-stall.sh [초=40]    — 같은 병목에서 BGP(TCP 179)·ARP 만 RED 밖 우선 클래스(1:5)로 보호
set -u
. "$(dirname "$0")/common.sh"
DUR=${1:-40}
O=$DATA/diag-stall${PROTECT:+-protect}; rm -rf "$O"; mkdir -p "$O"
bgpdrop() { dx spine1 vtysh -c "show bgp neighbors 10.1.1.5 json" | python3 -c 'import json,sys; v=list(json.load(sys.stdin).values())[0]; print(v.get("connectionsDropped",0), v.get("bgpState"))'; }
exec > >(tee "$O/output.txt") 2>&1
tcp_on
"$EXP/scripts/bottleneck.sh" spine tcp >/dev/null
"$EXP/scripts/inject-decap.sh" on >/dev/null
if [ -n "${PROTECT:-}" ]; then
  nsx spine1 tc class add dev eth3 parent 1: classid 1:5 htb rate 5mbit ceil 300mbit prio 0 quantum 1514
  nsx spine1 tc qdisc add dev eth3 parent 1:5 handle 5: pfifo limit 100
  nsx spine1 tc filter add dev eth3 parent 1: protocol ip prio 1 u32 match ip protocol 6 0xff match ip dport 179 0xffff flowid 1:5
  nsx spine1 tc filter add dev eth3 parent 1: protocol ip prio 1 u32 match ip protocol 6 0xff match ip sport 179 0xffff flowid 1:5
  nsx spine1 tc filter add dev eth3 parent 1: protocol arp prio 2 matchall flowid 1:5
  echo "보호: BGP·ARP → 1:5 (RED 밖)"
fi
B0=$(bgpdrop); echo "spine1→leaf3 BGP 끊긴 횟수(시작): $B0"
counters_on
P1=$(pid leaf1); P3=$(pid leaf3); PS=$(pid spine1)
nsenter -t $P1 -n tcpdump -i eth1 -s 128 -U -nn -w $O/leaf1-eth1-notect.pcap 'udp port 4789 and ip[1] & 3 = 0' >/dev/null 2>&1 & c1=$!
nsenter -t $P3 -n tcpdump -i eth1 -s 128 -U -nn -w $O/leaf3-eth1-notect.pcap 'udp port 4789 and ip[1] & 3 = 0' >/dev/null 2>&1 & c2=$!
# g1 자기 인터페이스에서 TCP 전부 (보낸 데이터와 돌아온 ACK, 앞 96B)
tcpdump -i xg1 -s 96 -U -nn -w $O/xg1-tcp.pcap tcp >/dev/null 2>&1 & c3=$!
sleep 1
python3 "$EXP/scripts/redpoll.py" $PS $((DUR + 6)) 0.2 > $O/red.csv &
rp=$!
ping -I vr1 -Q 0x02 -i 0.05 -D -O -W 1 -w $((DUR + 2)) $(ip_of 3) > $O/ping.txt 2>&1 &
pp=$!
python3 "$EXP/scripts/sampler.py" $O/sampler.csv $((DUR + 4)) & sp=$!
sleep 0.5
tcp_traffic $DUR $O/iperf
wait $sp $pp $rp 2>/dev/null
kill $c1 $c2 $c3 2>/dev/null; sleep 0.5
echo "spine1→leaf3 BGP 끊긴 횟수(끝): $(bgpdrop)   (시작 $B0)"
"$EXP/scripts/inject-decap.sh" off >/dev/null; "$EXP/scripts/bottleneck.sh" off >/dev/null
nsx spine1 tc -s qdisc show dev eth3 | head -5
echo "--- Not-ECT 바깥: leaf1:eth1(병목 앞) $(tcpdump -nn -r $O/leaf1-eth1-notect.pcap 2>/dev/null | grep -c '^[0-9]')   leaf3:eth1(병목 뒤) $(tcpdump -nn -r $O/leaf3-eth1-notect.pcap 2>/dev/null | grep -c '^[0-9]')"
echo "--- RED xstats 끝값: $(tail -1 $O/red.csv)"
