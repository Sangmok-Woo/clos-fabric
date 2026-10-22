#!/usr/bin/env bash
# 실험 14 공통 정의. 각 스크립트가 source 한다. WSL root 에서 실행.
#
#   송신 g1(leaf1)  g2(leaf2)  g4(leaf4)  ──VNI 10010──▶  수신 g3(leaf3)      모두 10.10.10.0/24
#   gN = WSL 기본 netns 의 VRF vrN(10.10.10.10N/32, rxe_xN 이 붙는다) + veth xgN ↔ leafN:eth6(br10010 포트)
#   병목(기본) spine1:eth3 egress = 바깥 헤더가 있는 VXLAN 구간.  spine2:eth3 은 내려서 경로를 spine1 로 고정
#   병목(대조) leaf3:eth6 egress  = 디캡 이후 구간
. "$(dirname "${BASH_SOURCE[0]}")/../../../../_tools/lab.sh"
EXP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ST=$EXP/state; mkdir -p "$ST"
DATA=$EXP/data; mkdir -p "$DATA"
CAPDIR=$EXP/capture

VNI=10010
SENDERS="1 2 4"
RCV=3
ip_of() { echo "10.10.10.10$1"; }
OOB=192.0.2.18            # perftest 의 TCP 교환용 주소(lo). 127.0.0.1 은 WSL 규칙(표 127)이 윈도우로 보낸다
RATE=300mbit              # 병목 포트 속도

T() { docker exec rtool "$@"; }
cnt() { cat /sys/class/infiniband/rxe_x$1/ports/1/hw_counters/$2 2>/dev/null || echo 0; }

# 병목 큐 정의 (트랙별). RED 의 ecn: ECT 패킷은 표시(CE), Not-ECT 는 버린다
#  tcp  : DCTCP 식 계단 표시 — 평균 큐 30KB 를 넘으면 전부 표시. 표시를 무시하면 1MB 까지 차고 꼬리 드랍
#  roce : 실험 11 과 같은 문턱(100~300KB). 흉내 DCQCN 이 ms 단위로 반응하기 때문.
#         버퍼는 1MB — rxe 세 대가 응답 없이 내보낼 수 있는 양(128 PSN × 4KB × 3 ≈ 1.5MB)보다 작게.
#         (Step 0·1 은 이 값을 정하기 전이라 4MB 로 돌렸다. 표시 전달만 보는 단계라 결과에 영향 없다)
red_def() {
  case $1 in
    tcp)  echo "red limit 1000000 min 30000 max 31000 avpkt 1500 burst 21 probability 1.0 bandwidth $RATE ecn" ;;
    roce) echo "red limit 1000000 min 100000 max 300000 avpkt 4200 burst 25 probability 0.5 bandwidth $RATE ecn" ;;
  esac
}

# bneck_on <노드> <dev> <트랙> — htb 300Mbit + RED(ecn)
bneck_on() {
  local n=$1 d=$2 tr=$3
  nsx $n tc qdisc del dev $d root 2>/dev/null
  nsx $n tc qdisc add dev $d root handle 1: htb default 10
  nsx $n tc class add dev $d parent 1: classid 1:10 htb rate $RATE ceil $RATE quantum 60000
  nsx $n tc qdisc add dev $d parent 1:10 handle 10: $(red_def $tr)
}
bneck_off() { nsx $1 tc qdisc del dev $2 root 2>/dev/null; true; }

# 계수기 — flower 필터 + action continue (패킷을 바꾸지 않고 세기만). pref 로 이름을 붙인다
#  leaf3:eth1 ingress  pref 11 바깥 VXLAN 전체 / 12 바깥 CE          (장애1 pedit 은 pref 50 → 세고 나서 지운다)
#  xg3 ingress(호스트) pref 2N 송신자 N 바이트 / 11 안쪽 CE / 12 안쪽 ECT(0)·(1) / 13 안쪽 Not-ECT
#  xg3 egress(호스트)  pref 11 ECE 가 켜진 TCP(수신측 알림) / 12 CNP(UDP 4792)
counters_on() {
  local P3; P3=$(pid leaf3)
  nsenter -t $P3 -n tc qdisc replace dev eth1 clsact
  nsenter -t $P3 -n tc filter del dev eth1 ingress pref 11 2>/dev/null
  nsenter -t $P3 -n tc filter del dev eth1 ingress pref 12 2>/dev/null
  nsenter -t $P3 -n tc filter add dev eth1 ingress pref 11 protocol ip flower ip_proto udp dst_port 4789 action continue
  nsenter -t $P3 -n tc filter add dev eth1 ingress pref 12 protocol ip flower ip_proto udp dst_port 4789 ip_tos 0x03/0x03 action continue
  tc qdisc replace dev xg$RCV clsact
  tc filter del dev xg$RCV ingress 2>/dev/null; tc filter del dev xg$RCV egress 2>/dev/null
  for n in $SENDERS; do
    tc filter add dev xg$RCV ingress pref 2$n protocol ip flower src_ip $(ip_of $n) action continue
  done
  tc filter add dev xg$RCV ingress pref 11 protocol ip flower ip_tos 0x03/0x03 action continue
  tc filter add dev xg$RCV ingress pref 12 protocol ip flower ip_tos 0x02/0x03 action continue
  tc filter add dev xg$RCV ingress pref 14 protocol ip flower ip_tos 0x01/0x03 action continue
  tc filter add dev xg$RCV ingress pref 13 protocol ip flower ip_tos 0x00/0x03 action continue
  tc filter add dev xg$RCV egress pref 11 protocol ip flower ip_proto tcp tcp_flags 0x40/0x40 action continue
  tc filter add dev xg$RCV egress pref 12 protocol ip flower ip_proto udp dst_port 4792 action continue
}
counters_off() {
  nsx leaf3 tc filter del dev eth1 ingress pref 11 2>/dev/null
  nsx leaf3 tc filter del dev eth1 ingress pref 12 2>/dev/null
  tc qdisc del dev xg$RCV clsact 2>/dev/null; true
}

# 장애1 — 수신 리프 업링크 ingress 에서 바깥 CE(11) → ECT(0)(10). DSCP 6비트는 retain 으로 그대로 둔다
decap_fault_on() {
  for d in eth1 eth2; do
    nsx leaf3 tc qdisc replace dev $d clsact
    nsx leaf3 tc filter del dev $d ingress pref 50 2>/dev/null
    nsx leaf3 tc filter add dev $d ingress pref 50 protocol ip flower ip_proto udp dst_port 4789 ip_tos 0x03/0x03 \
      action pedit ex munge ip tos set 0x02 retain 0x03 pipe action csum ip
  done
}
decap_fault_off() { for d in eth1 eth2; do nsx leaf3 tc filter del dev $d ingress pref 50 2>/dev/null; done; true; }

# 장애2 — 송신 리프 업링크 egress 에서 바깥 ECN 을 Not-ECT(00)로. VXLAN(UDP 4789)만
encap_fault_on() {
  for n in $SENDERS; do for d in eth1 eth2; do
    nsx leaf$n tc qdisc replace dev $d clsact
    nsx leaf$n tc filter del dev $d egress pref 50 2>/dev/null
    nsx leaf$n tc filter add dev $d egress pref 50 protocol ip flower ip_proto udp dst_port 4789 \
      action pedit ex munge ip tos set 0x00 retain 0x03 pipe action csum ip
  done; done
}
encap_fault_off() { for n in $SENDERS; do for d in eth1 eth2; do nsx leaf$n tc filter del dev $d egress pref 50 2>/dev/null; done; done; true; }

# 트랙 B: 기본 netns 의 TCP 를 DCTCP + ECN 으로 (원래 값은 state/tcp, teardown 이 되돌린다)
tcp_on() {
  [ -f "$ST/tcp" ] || sysctl -n net.ipv4.tcp_ecn net.ipv4.tcp_congestion_control > "$ST/tcp"
  sysctl -qw net.ipv4.tcp_ecn=1 net.ipv4.tcp_congestion_control=dctcp
}

# tcp_traffic <초> <출력 접두어> — g1·g2·g4 → g3 iperf3 (DCTCP, MSS 1448) 동시에. 결과 <접두어>-gN.json
tcp_traffic() {
  local dur=$1 pre=$2 n
  for n in $SENDERS; do
    T timeout $((dur + 20)) iperf3 -s -1 -p 530$n --bind-dev vr$RCV >/dev/null 2>&1 &
  done
  sleep 1
  local w=()
  for n in $SENDERS; do
    timeout $((dur + 20)) docker exec rtool iperf3 -c $(ip_of $RCV) -p 530$n --bind-dev vr$n -C dctcp -M 1448 \
      -t $dur -i 1 -J > "$pre-g$n.json" 2>/dev/null & w+=($!)
  done
  wait "${w[@]}"
}

# roce_traffic <초> <출력 접두어> <tclass> — g1·g2·g4 → g3 ib_write_bw 64KB 메시지 동시에. 결과 <접두어>-gN.txt
roce_traffic() {
  local dur=$1 pre=$2 tcl=$3 n p=18610
  for n in $SENDERS; do
    T sh -c "timeout $((dur + 20)) ib_write_bw -d rxe_x$RCV -x 1 -p $((p + n)) -s 65536 -D $dur -F --tclass=$tcl > /tmp/s18-$n.txt 2>&1" &
  done
  sleep 1.5
  local w=()
  for n in $SENDERS; do
    timeout -s KILL $((dur + 20)) docker exec rtool ib_write_bw -d rxe_x$n -x 1 -p $((p + n)) -s 65536 -D $dur -F \
      --tclass=$tcl --report_gbits $OOB > "$pre-g$n.txt" 2>&1 & w+=($!)
  done
  wait "${w[@]}"
  pkill -9 -f 'ib_write_bw -d rxe_x' 2>/dev/null; true
}

# 흉내 DCQCN 의 송신측 htb (실험 11 sender_queue 와 같은 모양): RoCE 클래스(DSCP 26)를 1:10 으로
sender_queue() {
  local d=xg$1
  tc qdisc del dev $d root 2>/dev/null
  tc qdisc add dev $d root handle 1: htb default 20
  tc class add dev $d parent 1: classid 1:10 htb rate 1000mbit ceil 1000mbit quantum 60000
  tc class add dev $d parent 1: classid 1:20 htb rate 10gbit ceil 10gbit quantum 60000
  tc qdisc add dev $d parent 1:10 handle 11: pfifo limit 10000
  tc qdisc add dev $d parent 1:20 handle 12: pfifo limit 10000
  tc filter add dev $d parent 1: protocol ip prio 1 u32 match ip dsfield 0x68 0xfc flowid 1:10
}

# vxlan tos 옵션: 0(기본, 바깥 DSCP 0) | inherit(안쪽 DSCP 복사) | 0x68 같은 고정값. 네 리프 모두
vx_tos() { local n; for n in 1 2 3 4; do dx leaf$n ip link set vni$VNI type vxlan tos $1; done; }
