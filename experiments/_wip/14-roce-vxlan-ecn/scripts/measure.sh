#!/usr/bin/env bash
# 측정 한 벌. 사용: measure.sh <이름> [반복=3] [초=60]
# 송신 v1·x2·x4 → 수신 v3 동시 iperf3 (DCTCP, 3:1 인캐스트). 1초마다 병목 큐·ECN 카운터를 찍고, v1 → v3 ping 으로 RTT.
# ping 은 ECT(0)(-Q 2)로 보낸다. Not-ECT 면 RED 가 마킹 대신 버려서 큐 지연을 못 잰다.
# 결과: data/<이름>-r<N>.csv (1초 시계열), data/summary.csv (한 줄 요약). 지금 걸린 장애·병목은 그대로 둔 채 잰다.
. "$(dirname "$0")/common.sh"
NAME=$1; REPS=${2:-3}; DUR=${3:-60}
[ -z "$NAME" ] && { echo "사용: measure.sh <이름> [반복] [초]"; exit 1; }

# 병목이 지금 어디 걸려 있나
if nsx leaf3 tc qdisc show dev eth4 | grep -q 'qdisc red'; then BN="$BN_RXPORT"; else BN="$BN_SPINE"; fi
set -- $BN; BNN=$1; BND=$2

# 한 줄 표본: 시각, 병목 tc(JSON), 수신 ECN 카운터, 송신 합계 카운터
sample() {
  local t; t=$(date +%s.%N)
  local q; q=$(nsx $BNN tc -s -j qdisc show dev $BND)
  local rx; rx=$(nsx $RX cat /proc/net/netstat | awk 'NR%2==1{split($0,h)} NR%2==0{split($0,v); for(i=2;i<=length(h);i++) if(h[i]~/^In(CE|ECT0|ECT1|NoECT)Pkts$/) printf "%s=%s ", h[i], v[i]}')
  local tx=""
  for s in $SENDERS; do
    tx+=$(nsx $s cat /proc/net/netstat /proc/net/snmp | awk -v s=$s 'NR%2==1{split($0,h)} NR%2==0{split($0,v); for(i=2;i<=length(h);i++) if(h[i]~/^(RetransSegs|TCPDeliveredCE|OutSegs|TCPDelivered)$/) printf "%s.%s=%s ", s, h[i], v[i]}')
  done
  local dec; dec=$(nsx leaf3 tc -s -j filter show dev eth1 ingress 2>/dev/null | tr -d '\n')
  printf '%s\t%s\t%s\t%s\t%s\n' "$t" "$q" "$rx" "$tx" "${dec:-[]}"
}

for r in $(seq 1 $REPS); do
  say "$NAME r$r — 병목 $BNN $BND, ${DUR}초"
  W=$CAP/$NAME-r$r; rm -rf "$W"; mkdir -p "$W"
  dx $RX pkill iperf3 2>/dev/null; sleep 0.5
  for s in $SENDERS; do dx $RX iperf3 -s -D -p ${PORT[$s]}; done
  sleep 1
  sample > "$W/samples.tsv"
  ( for i in $(seq 1 $((DUR + 3))); do sleep 1; sample; done >> "$W/samples.tsv" ) &
  SP=$!
  nsx v1 ping -D -O -Q 2 -i 0.2 -w $((DUR + 2)) $RX_IP > "$W/ping.txt" 2>&1 &
  PP=$!
  date +%s.%N > "$W/t_start"   # iperf 1초 칸과 표본을 시각으로 맞추는 기준
  for s in $SENDERS; do
    dx $s iperf3 -c $RX_IP -p ${PORT[$s]} -t $DUR -i 1 -J --get-server-output > "$W/iperf-$s.json" 2>&1 &
  done
  wait $(jobs -p | grep -v -e "^$SP$" -e "^$PP$") 2>/dev/null
  wait $PP; wait $SP
  python3 "$EXP/scripts/collect.py" "$W" "$NAME" "$r" "$BNN $BND" "$DATA"
  sleep 3
done
dx $RX pkill iperf3 2>/dev/null; true
