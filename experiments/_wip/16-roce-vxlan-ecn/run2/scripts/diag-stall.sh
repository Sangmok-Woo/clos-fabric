#!/usr/bin/env bash
# 장애1(디캡 CE 누락)의 '전면 정지' 원인 좁히기 — 1회차 README 의 "설명 못 한 것" 후속.
#   정지 구간에 큐는 비었는데 병목 RED 드랍이 초당 몇 개씩 남는다. 무엇이, 왜 버려지는가.
#   1) spine1:eth3 RED xstats(marked/early/pdrop/other)와 큐 바이트를 0.2초마다
#   2) 병목 앞(leaf1:eth1)과 뒤(leaf3:eth1)에서 '바깥 ECN 이 Not-ECT 인 VXLAN'만 캡처 (작다)
#   3) 병목 앞(leaf1:eth1)에서 g1 흐름의 안쪽 TCP 를 앞 128B 만 (재전송·RTO 확인용)
#   4) g1 → g3 ECT ping (-Q 2) 50ms 간격
#   diag-stall.sh [초=40]   — setup.sh 다음, 다른 측정이 없을 때
set -u
. "$(dirname "$0")/common.sh"
DUR=${1:-40}
O=$DATA/diag-stall; rm -rf "$O"; mkdir -p "$O"
exec > >(tee "$O/output.txt") 2>&1
tcp_on
"$EXP/scripts/bottleneck.sh" spine tcp >/dev/null
"$EXP/scripts/inject-decap.sh" on >/dev/null
counters_on
P1=$(pid leaf1); P3=$(pid leaf3); PS=$(pid spine1)
nsenter -t $P1 -n tcpdump -i eth1 -s 128 -U -nn -w $O/leaf1-eth1-notect.pcap 'udp port 4789 and ip[1] & 3 = 0' >/dev/null 2>&1 & c1=$!
nsenter -t $P3 -n tcpdump -i eth1 -s 128 -U -nn -w $O/leaf3-eth1-notect.pcap 'udp port 4789 and ip[1] & 3 = 0' >/dev/null 2>&1 & c2=$!
# g1 → g3 데이터만 (UDP 머리 기준 8+8+14 = 30 바이트 뒤가 안쪽 IP, 그 +12 가 출발 주소 10.10.10.101)
nsenter -t $P1 -n tcpdump -i eth1 -s 128 -U -nn -w $O/leaf1-eth1-g1.pcap 'udp port 4789 and udp[42:4] = 0x0a0a0a65' >/dev/null 2>&1 & c3=$!
sleep 1
( end=$(( $(date +%s) + DUR + 6 ))
  echo "t,backlog,drops,marked,early,pdrop,other"
  t0=$(date +%s.%N)
  while [ "$(date +%s)" -lt $end ]; do
    nsenter -t $PS -n tc -s -j qdisc show dev eth3 | python3 -c '
import json,sys,time
q=[q for q in json.load(sys.stdin) if q.get("handle")=="10:"][0]
x=q.get("options",{})
print(f"{time.time()-float(sys.argv[1]):.2f},{q[\"backlog\"]},{q[\"drops\"]},{q.get(\"marked\",0)},{q.get(\"early\",0)},{q.get(\"pdrop\",0)},{q.get(\"other\",0)}")' $t0
    sleep 0.2
  done ) > $O/red.csv &
rp=$!
ping -I vr1 -Q 0x02 -i 0.05 -D -O -W 1 -w $((DUR + 2)) $(ip_of 3) > $O/ping.txt 2>&1 &
pp=$!
python3 "$EXP/scripts/sampler.py" $O/sampler.csv $((DUR + 4)) & sp=$!
sleep 0.5
tcp_traffic $DUR $O/iperf
wait $sp $pp $rp 2>/dev/null
kill $c1 $c2 $c3 2>/dev/null; sleep 0.5
"$EXP/scripts/inject-decap.sh" off >/dev/null; "$EXP/scripts/bottleneck.sh" off >/dev/null
nsx spine1 tc -s qdisc show dev eth3 | head -5
echo "--- Not-ECT 바깥: leaf1:eth1(병목 앞) $(tcpdump -nn -r $O/leaf1-eth1-notect.pcap 2>/dev/null | grep -c '^[0-9]')   leaf3:eth1(병목 뒤) $(tcpdump -nn -r $O/leaf3-eth1-notect.pcap 2>/dev/null | grep -c '^[0-9]')"
echo "--- RED xstats 끝값: $(tail -1 $O/red.csv)"
