#!/usr/bin/env bash
# RoCEv2 를 패브릭 위에 깔고, 지나가는 패킷을 보고, 근거를 들어 튜닝한다.
#   g1~g4 = RoCE 서버 (setup.sh 가 만든 VRF + Soft-RoCE rxe 장치), leafN:eth5 에 붙어 있다
#   R1 설치·연결   R2 패킷 해부   R3 MTU   R4 손실 한 번의 값   R5 인캐스트와 큐 튜닝   R6 ECMP 엔트로피   R7 카운터
# 사용: run.sh            전부
#       run.sh R4 R5      일부만 (캡처·출력은 해당 구간만 덧붙인다)
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=128
ST=$HERE/state; mkdir -p "$CAPDIR" "$ST"
STEPS=${*:-R1 R2 R3 R4 R5 R6 R7}
[ $# -eq 0 ] && rm -f "$CAPDIR"/*.pcap "$CAPDIR/run-output.txt"
exec > >(tee -a "$CAPDIR/run-output.txt") 2>&1

T() { docker exec rtool "$@"; }                       # 도구 상자 (기본 네임스페이스)
cnt() { cat /sys/class/infiniband/rxe_$1/ports/1/hw_counters/$2; }
snap() { for d in g1 g2 g3 g4; do for k in sent_pkts rcvd_pkts duplicate_request out_of_seq_request rcvd_seq_err completer_retry_err retry_exceeded_err send_err ack_deferred; do echo "$d $k $(cnt $d $k)"; done; done > "$ST/c.$1"; }
delta() {   # delta <이전> <이후> <장치> <카운터>
  echo $(( $(awk -v d=$3 -v k=$4 '$1==d&&$2==k{print $3}' "$ST/c.$2") - $(awk -v d=$3 -v k=$4 '$1==d&&$2==k{print $3}' "$ST/c.$1") ))
}
clean() { pkill -9 -f 'ib_(write|send|read)_(bw|lat)' 2>/dev/null; pkill -9 -f rping 2>/dev/null; sleep 1; }

# bw <보내는> <받는> <포트> <초> [perftest 옵션...] → 평균 Gb/s (받는 쪽이 서버, 대역 밖 정보 교환은 루프백 TCP)
bw() {
  local s=$1 d=$2 p=$3 t=$4; shift 4
  T sh -c "timeout $((t + 12)) ib_write_bw -d rxe_$d -x 1 -p $p -D $t -F $* > /tmp/srv$p.txt 2>&1" & local sp=$!
  sleep 1.5
  timeout -s KILL $((t + 12)) docker exec rtool ib_write_bw -d rxe_$s -x 1 -p $p -D $t -F --report_gbits "$@" 127.0.0.1 2>&1 \
    | awk '/^ *[0-9]+ +[0-9]+ /{v=$4} END{print (v==""?"실패":v)}'
  wait $sp 2>/dev/null   # 그냥 wait 하면 백그라운드 tcpdump 까지 기다린다
}
tcp() {   # tcp <보내는> <받는> <초> → Gb/s
  local s=$1 d=$2 t=$3
  T sh -c "timeout $((t + 8)) iperf3 -s -1 -p 5301 >/dev/null 2>&1" & local sp=$!; sleep 1
  timeout $((t + 8)) docker exec rtool iperf3 -c 172.16.2${d#g}.10 -B 172.16.2${s#g}.10 --bind-dev vg${s#g} -p 5301 -t $t -f g 2>&1 \
    | awk '/receiver/{print $7}'
  wait $sp 2>/dev/null
}
txb() { dx $1 cat /sys/class/net/$2/statistics/tx_bytes; }
tcq() { nsx leaf3 tc -s qdisc show dev eth5 | grep -o 'dropped [0-9]*' | head -1 | awk '{print $2}'; }

R1() {
  say "R1 설치와 연결 — 커널 모듈, 장치, GID"
  lsmod | grep -E '^(rdma_rxe|ib_core|ib_uverbs|crc32_generic) ' | awk '{print "  " $1}'
  T rdma link | grep rxe_g | sed 's/^/  /'
  T ibv_devinfo -d rxe_g1 | grep -E 'transport|active_mtu|max_mtu|link_layer|state' | sed 's/^\s*/  /'
  echo "  rxe_g1 GID[1] = $(cat /sys/class/infiniband/rxe_g1/ports/1/gids/1)  (IPv4 172.16.21.10 을 IPv6 모양으로)"
  echo "  수신 소켓: $(ss -uln | awk '$4 ~ /:4791$/{print $4}' | tr '\n' ' ') ← 기본 네임스페이스에만 있다"
  say "R1 연결 — rdma_cm (rping) 협상을 캡처"
  SNAP=400 cap_start r1-cm-leaf3 leaf3 eth5 udp port 4791   # CM 메시지(MAD 256B)는 통째로
  cap_wait 1
  T sh -c 'timeout 6 rping -s -a 172.16.23.10 -C 3 > /tmp/rps.txt 2>&1' & sp=$!
  sleep 1
  timeout -s KILL 6 docker exec rtool rping -c -a 172.16.23.10 -I 172.16.21.10 -C 3 -v 2>&1 | head -3 | sed 's/^/  client: /'
  wait $sp 2>/dev/null; clean
  sed 's/^/  server: /' /tmp/rps.txt | head -3
  cap_stop
  say "R1 연결 — perftest 방식 (QP 정보를 TCP 로 교환, RoCE 는 바로 데이터)"
  cap_start r1-first-leaf3 leaf3 eth5 udp port 4791
  cap_wait 1
  echo "  g1 → g3 ib_write_bw 64KB × 3초: $(bw g1 g3 18515 3 -s 65536) Gb/s"
  cap_stop; clean
  head_pcap "$CAPDIR/r1-first-leaf3.pcap" 400
}

R2() {
  say "R2 패킷 해부 — Write / Send / Read 를 8KB 메시지 5개씩"
  # 패킷 45개뿐이라 통째로 (잘린 패킷은 Wireshark 가 길이 불일치로 Malformed 표시를 한다)
  SNAP=4300 cap_start r2-leaf1 leaf1 eth5 udp port 4791
  SNAP=4300 cap_start r2-leaf3 leaf3 eth5 udp port 4791
  cap_wait 1
  for op in write send read; do
    T sh -c "timeout 10 ib_${op}_bw -d rxe_g3 -x 1 -p 18520 -s 8192 -n 5 -F > /tmp/srv.txt 2>&1" & sp=$!; sleep 1.5
    timeout -s KILL 10 docker exec rtool ib_${op}_bw -d rxe_g1 -x 1 -p 18520 -s 8192 -n 5 -F 127.0.0.1 >/dev/null 2>&1
    wait $sp 2>/dev/null; sleep 1
  done
  cap_stop; clean
}

R3() {
  say "R3 RoCE MTU — 64KB 메시지, 4초씩 (병목은 CPU: Soft-RoCE 는 패킷마다 CPU 가 일한다)"
  for m in 1024 2048 4096; do
    snap a
    v=$(bw g1 g3 18530 4 -s 65536 -m $m); snap b
    echo "  MTU $m: $v Gb/s, 보낸 패킷 $(delta a b g1 sent_pkts), 받은 ACK $(delta a b g1 rcvd_pkts)"
    clean
  done
  say "R3 메시지 크기 — MTU 4096, 크기별 (작은 메시지는 패킷당 고정비용이 지배)"
  for s in 64 1024 4096 16384 65536 1048576; do
    echo "  ${s}B: $(bw g1 g3 18531 3 -s $s) Gb/s"; clean
  done
}

R4() {
  say "R4 손실 한 번의 값 — leaf3:eth5(→g3) 에 무작위 손실, RoCE vs TCP"
  for l in 0 0.01 0.1 1; do
    if [ "$l" = 0 ]; then nsx leaf3 tc qdisc del dev eth5 root 2>/dev/null
    else nsx leaf3 tc qdisc replace dev eth5 root netem loss gemodel ${l}% 100% 100% 0%; fi   # WSL 6.6 은 'loss N%' 가 안 먹는다
    [ "$l" = 0.1 ] && { cap_start r4-loss-leaf1 leaf1 eth5 udp port 4791; cap_start r4-loss-leaf3 leaf3 eth5 udp port 4791; cap_wait 1; }
    snap a; r=$(bw g1 g3 18540 5 -s 65536); snap b; clean
    [ "$l" = 0.1 ] && cap_stop
    t=$(tcp g1 g3 5)
    echo "  손실 ${l}%: RoCE $r Gb/s (g3 NAK seq_err $(delta a b g3 out_of_seq_request), 중복수신 $(delta a b g3 duplicate_request), g1 재시도 $(delta a b g1 completer_retry_err), 재시도 초과 $(delta a b g1 retry_exceeded_err)) | TCP $t Gb/s"
  done
  nsx leaf3 tc qdisc del dev eth5 root 2>/dev/null
  for f in r4-loss-leaf1 r4-loss-leaf3; do head_pcap "$CAPDIR/$f.pcap" 3000; done
}

incast() {   # incast <이름> <메시지 크기> [perftest 옵션...] : g1·g2·g4 → g3 동시에 6초, 그동안 g1→g3 ping (같은 큐를 지난다)
  local name=$1 sz=$2; shift 2; local d0 out
  snap a; d0=$(tcq)
  local pids=""
  for i in 1 2 4; do bw g$i g3 1855$i 6 -s $sz "$@" > "$ST/in.$i" & pids="$pids $!"; done
  (sleep 3; ping -I vg1 -c 10 -i 0.2 -W 1 -q 172.16.23.10 2>/dev/null | awk -F/ '/rtt/{print $5}') > "$ST/rtt" & pids="$pids $!"
  wait $pids
  snap b
  out="  $name: g1 $(cat $ST/in.1) + g2 $(cat $ST/in.2) + g4 $(cat $ST/in.4) Gb/s"
  echo "$out | 큐 드랍 $(( $(tcq) - d0 )), g3 NAK $(delta a b g3 out_of_seq_request), 중복수신 $(delta a b g3 duplicate_request), 송신측 재시도 $(( $(delta a b g1 completer_retry_err) + $(delta a b g2 completer_retry_err) + $(delta a b g4 completer_retry_err) )), ping 평균 $(cat $ST/rtt)ms"
  clean
}
R5() {
  say "R5 인캐스트 — g1·g2·g4 → g3, leaf3:eth5 를 300Mbit 포트로"
  echo "  혼자 보낼 때 g1 → g3: $(bw g1 g3 18550 4 -s 65536) Gb/s (병목 없음)"; clean
  for lim in 16kb 64kb 512kb 4mb; do
    nsx leaf3 tc qdisc replace dev eth5 root tbf rate 300mbit burst 32kb limit $lim
    [ $lim = 64kb ] && { cap_start r5-incast-leaf3 leaf3 eth5 udp port 4791; cap_wait 1; }
    incast "버퍼 $lim" 65536
    [ $lim = 64kb ] && cap_stop
  done
  nsx leaf3 tc qdisc replace dev eth5 root tbf rate 300mbit burst 32kb limit 64kb
  # 튜닝 1: 송신 속도 제한. perftest 의 SW 제한은 기본으로 메시지를 몰아서(burst) 보내므로 burst_size=1 로 패킷마다 간격을 둔다
  incast "버퍼 64kb + 속도 제한 90Mbit×3 (burst 기본값)" 4096 --rate_limit=0.09 --rate_limit_type=SW
  incast "버퍼 64kb + 속도 제한 90Mbit×3 (burst 1)" 4096 --rate_limit=0.09 --rate_limit_type=SW --burst_size=1
  incast "버퍼 64kb + 속도 제한 100Mbit×3 (burst 1, 합 300 = 포트 속도)" 4096 --rate_limit=0.1 --rate_limit_type=SW --burst_size=1
  # 튜닝 0: 재전송 타이머. 캡처에서 송신자가 65ms 씩 멈춘다 = perftest 기본 QP 타임아웃 -u 14 (4.096µs × 2^14 = 67ms)
  incast "버퍼 64kb + 타임아웃 -u 10 (4.2ms)" 4096 -u 10
  incast "버퍼 64kb + 타임아웃 -u 8 (1.0ms)" 4096 -u 8
  # 튜닝 2: 송신 창. 버퍼 64KB ÷ (3대 × 4KB) ≈ 5 → 한 대가 동시에 띄우는 메시지를 4개 이하로
  incast "버퍼 64kb + 창 4 (-t 4)" 4096 -t 4
  incast "버퍼 64kb + 창 16 (-t 16)" 4096 -t 16
  nsx leaf3 tc qdisc del dev eth5 root
  head_pcap "$CAPDIR/r5-incast-leaf3.pcap" 3000
}

R6() {
  say "R6 ECMP 엔트로피 — g1 → g3 QP 수별, leaf1 의 스파인 두 링크로 나간 바이트"
  local orig; orig=$(nsx leaf1 sysctl -n net.ipv4.fib_multipath_hash_policy); echo "$orig" > "$ST/hash"
  for pol in 0 1; do
    nsx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_policy=$pol; nsx leaf1 ip route flush cache
    echo "  leaf1 해시 정책 $pol ($([ $pol = 0 ] && echo 'IP 만' || echo 'IP + UDP 포트'))"
    for q in 1 2 4 8 16; do
      [ $q = 8 ] && { cap_start r6-qp8-pol$pol-leaf1 leaf1 eth5 udp port 4791; cap_wait 1; }
      a1=$(txb leaf1 eth1); a2=$(txb leaf1 eth2)
      v=$(bw g1 g3 18560 4 -s 65536 -q $q)
      b1=$(( $(txb leaf1 eth1) - a1 )); b2=$(( $(txb leaf1 eth2) - a2 ))
      [ $q = 8 ] && cap_stop >/dev/null
      echo "    QP $q: $v Gb/s, spine1 $((b1/1000000))MB : spine2 $((b2/1000000))MB"
      clean
    done
  done
  nsx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_policy=$orig
  echo "  QP 8 의 UDP 출발 포트 (QP 마다 하나):"
  tcpdump -nn -r "$CAPDIR/r6-qp8-pol1-leaf1.pcap" 'src host 172.16.21.10' 2>/dev/null | awk '{split($3,a,"."); print a[5]}' | sort | uniq -c | sed 's/^/   /'
  for f in r6-qp8-pol0-leaf1 r6-qp8-pol1-leaf1; do head_pcap "$CAPDIR/$f.pcap" 2000; done
}

R7() {
  say "R7 카운터 — 패브릭 모니터링이 못 보는 것"
  echo "  rxe 카운터 (누적, 서버 쪽 /sys/class/infiniband/*/ports/1/hw_counters):"
  for d in g1 g2 g3 g4; do
    printf "   %s" $d; for k in sent_pkts rcvd_pkts out_of_seq_request duplicate_request completer_retry_err retry_exceeded_err; do printf "  %s=%s" $k $(cnt $d $k); done; echo
  done
  echo "  같은 시간 패브릭 쪽 인터페이스 드랍 (모니터링 수집기가 읽는 값):"
  for n in leaf1 leaf2 leaf3 leaf4; do echo "   $n:eth5 tx_dropped=$(dx $n cat /sys/class/net/eth5/statistics/tx_dropped) rx_dropped=$(dx $n cat /sys/class/net/eth5/statistics/rx_dropped)"; done
}

clean
for s in $STEPS; do $s; done
clean
# 잘라 낸 pcap 과 실행 기록을 윈도우 쪽 저장소에 다시 복사 (cap_stop 은 자르기 전에 복사한다)
W=$WINROOT/$(basename "$HERE")/capture
[ -d "$WINROOT" ] && { mkdir -p "$W"; cp "$CAPDIR"/*.pcap "$CAPDIR/run-output.txt" "$W/"; }
