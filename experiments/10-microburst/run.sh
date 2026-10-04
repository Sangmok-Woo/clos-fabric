#!/usr/bin/env bash
# 마이크로버스트. 평균은 링크 용량보다 한참 낮은데 순간적으로 몰린 트래픽이 얕은 버퍼에서 버려진다.
# leaf3 → h3 포트를 100Mbit, 버퍼 64KB(100Mbit 에서 약 5ms)인 스위치 포트로 만든다 (tc tbf).
# h1·h2·h4 세 대가 h3 로 UDP 를 보낸다. 셋을 합친 평균은 두 Phase 모두 90Mbit/s 로 같다.
#   Phase smooth  -b 30M       고르게 (iperf3 기본 페이싱: 1ms 마다 몇 개씩)
#   Phase burst   -b 30M/300   평균은 같고, 300개(약 420KB)를 한 번에 몰아 보낸 뒤 쉰다
# 캡처: leaf3:eth1·eth2 (스파인에서 들어오는 쪽 = 제공된 트래픽), h3:eth1 (실제로 도착한 트래픽)
# 모니터링(5초 scrape)이 이 장애를 어떻게 보는지 Prometheus 에 묻는다.
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=64
ST=$HERE/state; rm -rf "$CAPDIR" "$ST"; mkdir -p "$CAPDIR" "$ST"
exec > >(tee "$CAPDIR/run-output.txt") 2>&1
DUR=10
PROM=http://localhost:9090

q() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "없음")'; }
tcdrop() { nsx leaf3 tc -s qdisc show dev eth3 | grep -o 'dropped [0-9]*' | head -1 | awk '{print $2}'; }
netdrop() { dx leaf3 cat /sys/class/net/eth3/statistics/tx_dropped; }

say "준비 — leaf3:eth3 을 100Mbit / 버퍼 64KB 포트로, h3 에 iperf3 서버 3개"
nsx leaf3 tc qdisc replace dev eth3 root tbf rate 100mbit burst 32kb limit 64kb
# iperf3 -D(데몬)는 docker exec 가 끝나면 같이 죽는다 → nohup 백그라운드로 띄운다
dx h3 pkill iperf3; for p in 5201 5202 5203; do dx h3 sh -c "nohup iperf3 -s -p $p >/dev/null 2>&1 &"; done
sleep 1
cap_start leaf3-eth1 leaf3 eth1 udp portrange 5201-5203
cap_start leaf3-eth2 leaf3 eth2 udp portrange 5201-5203
cap_start h3-eth1    h3    eth1 udp portrange 5201-5203
cap_wait 1

phase() {   # phase <이름> <iperf3 -b 값>
  local t0 t1 d0 n0
  say "Phase $1 — 세 대가 각각 -b $2, ${DUR}초"
  d0=$(tcdrop); n0=$(netdrop); t0=$(date +%s.%N)
  echo "$1 $t0" >> "$ST/timeline"
  local pids="" i=1
  for h in h1 h2 h4; do
    (timeout $((DUR + 15)) docker exec "$(c $h)" iperf3 -c 172.16.13.10 -p 520$i -u -b "$2" -l 1400 -t $DUR 2>&1 | awk -v h=$h '/receiver/{print "  " h " → h3: 받은 쪽 " $7 " " $8 ", 손실 " $(NF-1) " " $NF}') &
    pids="$pids $!"; i=$((i+1))
  done
  wait $pids   # 그냥 wait 하면 백그라운드 tcpdump(캡처)까지 기다려서 끝나지 않는다
  t1=$(date +%s.%N); echo "$1-end $t1" >> "$ST/timeline"
  sleep 12   # scrape 두 번 이상 지나가게
  echo "  leaf3:eth3 버퍼에서 버려진 패킷 (tc): $(( $(tcdrop) - d0 ))"
  echo "  같은 포트의 인터페이스 카운터 tx_dropped: $(( $(netdrop) - n0 ))  ← 모니터링 수집기가 읽는 값"
  echo "  모니터링이 본 leaf3:eth3 송신 속도 (5초 scrape, 구간 최대): $(q "max_over_time((rate(clos_if_tx_bytes_total{node=\"leaf3\",ifname=\"eth3\"}[10s])*8/1e6)[$((DUR+12))s:5s])" | cut -c1-5) Mbit/s"
  echo "  그동안 울린 InterfaceDropping 알람: $(q "count(max_over_time(ALERTS{alertname=\"InterfaceDropping\",alertstate=\"firing\"}[$((DUR+12))s])) or vector(0)")"
}
phase smooth 30M
phase burst 30M/300

cap_stop
say "원복"
nsx leaf3 tc qdisc del dev eth3 root
dx h3 pkill iperf3
nsx leaf3 tc qdisc show dev eth3

say "1ms 단위로 다시 세기 (캡처)"
python3 "$HERE/io.py" "$CAPDIR" "$ST/timeline" "$HERE/img"
W=$WINROOT/$(basename "$HERE"); mkdir -p "$W/img" && cp "$HERE"/img/* "$W/img/" 2>/dev/null; cp "$CAPDIR/run-output.txt" "$W/capture/" 2>/dev/null
