#!/usr/bin/env bash
# 장애 1 — 디캡 때 CE 누락. 사용: inject-decap.sh on | off | show
# leaf3 업링크(eth1·eth2) ingress 에서, VXLAN(UDP 4789) 바깥 IP 헤더가 CE(11)면 ECT(0)(10)으로 되돌린다.
# DSCP 6비트는 그대로 둔다(retain 0x03 = ECN 2비트만 바꿈). IP 체크섬은 csum 으로 다시 계산.
# tcpdump 는 tc ingress 보다 앞에서 보므로, leaf3 eth1 캡처에는 스파인이 찍은 CE 가 그대로 보인다.
. "$(dirname "$0")/common.sh"
L=leaf3
case "${1:-show}" in
  on)
    for d in eth1 eth2; do
      nsx $L tc qdisc replace dev $d clsact
      nsx $L tc filter del dev $d ingress pref 16 2>/dev/null
      nsx $L tc filter add dev $d ingress pref 16 protocol ip flower ip_proto udp dst_port 4789 ip_tos 0x03/0x03 \
        action pedit ex munge ip tos set 0x02 retain 0x03 pipe action csum ip
    done ;;
  off)
    for d in eth1 eth2; do nsx $L tc qdisc del dev $d clsact 2>/dev/null; done; true ;;
esac
for d in eth1 eth2; do
  n=$(nsx $L tc -s filter show dev $d ingress 2>/dev/null | awk '/action order 1: *pedit/{f=1} f&&/Sent/{print $4; exit}')
  echo "  $L $d ingress CE→ECT0 필터: ${n:-없음}${n:+ 패킷}"
done
