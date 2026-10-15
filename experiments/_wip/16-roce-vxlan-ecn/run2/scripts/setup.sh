#!/usr/bin/env bash
# 실험 18 준비 (멱등). 패브릭 베이스(BGP·EVPN)가 정상일 때만 진행한다.
#  1) rxe 모듈·rtool 컨테이너
#  2) VNI 10010 을 leaf2·leaf4 에도 (베이스는 leaf1·leaf3 만), VNI·브리지 MTU 1500 → 9000
#  3) g1~g4: VRF vrN + veth xgN ↔ leafN:eth6(br10010), rxe_xN
#  4) 경로 고정: spine2:eth3 을 내려 leaf3 로 가는 VXLAN 이 전부 spine1:eth3 을 지나게
# 바꾸기 전 값은 state/ 에 적고 teardown.sh 가 되돌린다.
set -u
. "$(dirname "$0")/common.sh"

say "0) 베이스 점검"
bad=0
for n in spine1 spine2; do
  e=$(dx $n vtysh -c "show bgp summary json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin)["ipv4Unicast"]["peers"]; print(sum(p["state"]=="Established" for p in d.values()))')
  echo "  $n BGP Established $e/4"; [ "$e" = 4 ] || bad=1
done
[ "$(dx spine2 cat /sys/class/net/eth3/operstate)" = down ] && bad=0   # 이미 setup 을 한 번 했다 (spine2 세션 하나는 일부러 내려 둔 상태)
dx leaf1 vtysh -c "show evpn vni $VNI" >/dev/null 2>&1 || { echo "  leaf1 에 VNI $VNI 이 없다 — scripts/evpn-apply.sh 먼저"; bad=1; }
[ $bad = 0 ] || { echo "베이스가 정상이 아니라 멈춘다"; exit 1; }

say "1) rxe 모듈 · rtool"
modprobe ib_core; modprobe ib_uverbs
lsmod | grep -q '^crc32_generic' || insmod /root/kbuild/crc32mod/crc32_generic.ko
lsmod | grep -q '^rdma_rxe' || insmod /root/kbuild/linux/drivers/infiniband/sw/rxe/rdma_rxe.ko
for m in tcp_dctcp cls_flower act_pedit act_csum sch_red sch_htb; do modprobe $m; done
docker image inspect rdma-tools >/dev/null 2>&1 || docker build -q --network host -t rdma-tools "$EXP/../../12-roce/tools"
docker ps --format '{{.Names}}' | grep -qx rtool || { docker rm -f rtool >/dev/null 2>&1
  docker run -d --name rtool --network host --privileged -v /dev/infiniband:/dev/infiniband -v /tmp:/tmp rdma-tools sleep infinity >/dev/null; }
ip addr show dev lo | grep -q "$OOB/32" || ip addr add $OOB/32 dev lo
# VRF 안 소켓이 기본 VRF 의 리스너(perftest 교환·iperf3)에 붙을 수 있게
[ -f "$ST/l3mdev" ] || sysctl -n net.ipv4.tcp_l3mdev_accept net.ipv4.udp_l3mdev_accept > "$ST/l3mdev"
sysctl -qw net.ipv4.tcp_l3mdev_accept=1 net.ipv4.udp_l3mdev_accept=1
lsmod | grep -E '^(rdma_rxe|tcp_dctcp)' | awk '{print "  "$1}'

say "2) VNI $VNI 를 leaf2·leaf4 에도, MTU 9000"
for n in 2 4; do
  if ! dx leaf$n ip link show vni$VNI >/dev/null 2>&1; then
    touch "$ST/vni-leaf$n"
    dx leaf$n sh -c "ip link add br$VNI type bridge; ip link set br$VNI type bridge stp_state 0; ip link set br$VNI up
      ip link add vni$VNI type vxlan id $VNI dstport 4789 local 10.255.1.$n nolearning
      ip link set vni$VNI master br$VNI; ip link set vni$VNI up
      bridge link set dev vni$VNI neigh_suppress on learning off"
    dx leaf$n vtysh -c "conf t" -c "router bgp 6501$n" -c "address-family l2vpn evpn" -c "advertise-all-vni" >/dev/null
    echo "  leaf$n: br$VNI + vni$VNI (VTEP 10.255.1.$n) 새로 만듦"
  fi
done
for n in 1 2 3 4; do
  [ -f "$ST/mtu-leaf$n" ] || dx leaf$n cat /sys/class/net/vni$VNI/mtu > "$ST/mtu-leaf$n"
  dx leaf$n ip link set vni$VNI mtu 9000
  dx leaf$n ip link set br$VNI mtu 9000
done
echo "  vni/br MTU 9000 (언더레이 9500 이 VXLAN 50B 를 감당)"

say "3) g1~g4 (VRF + veth + rxe)"
for n in 1 2 3 4; do
  if ! ip link show xg$n >/dev/null 2>&1; then
    ip link add vr$n type vrf table 18$n; ip link set vr$n up
    ip link add xg$n type veth peer name eth6 netns "$(pid leaf$n)"
    ip link set xg$n master vr$n; ip link set xg$n mtu 9000 up
    ip addr add $(ip_of $n)/32 dev vr$n
    ip route add 10.10.10.0/24 dev xg$n vrf vr$n src $(ip_of $n)
    dx leaf$n ip link set eth6 mtu 9000 master br$VNI up
  fi
  T rdma link show rxe_x$n >/dev/null 2>&1 || T rdma link add rxe_x$n type rxe netdev vr$n
done
sleep 2
T rdma link | grep rxe_x | sed 's/^/  /'

say "4) 경로 고정 — spine2:eth3(→leaf3) 내림"
# state 파일만 믿으면 안 된다: 패브릭을 재배포하면 eth3 은 다시 올라와 있는데 파일은 남는다 (2026-10-15 에 한 번 당함)
if [ "$(dx spine2 cat /sys/class/net/eth3/operstate)" != down ]; then
  nsx spine2 ip link set eth3 down; touch "$ST/spine2-eth3-down"
fi
for i in $(seq 30); do
  nh=$(dx leaf1 ip route get 10.255.1.3 | grep -c 'dev eth1')
  multi=$(dx leaf1 ip route show 10.255.1.3 | grep -c nexthop)
  [ "$nh" = 1 ] && [ "$multi" = 0 ] && break; sleep 1
done
for n in $SENDERS; do echo "  leaf$n → leaf3 VTEP: $(dx leaf$n ip route show 10.255.1.3 | head -1)"; done

say "5) 확인"
for i in $(seq 20); do ping -I vr1 -c 1 -W 1 -q $(ip_of 3) >/dev/null 2>&1 && break; sleep 1; done
for n in $SENDERS; do
  printf "  g%s → g3 ping: " $n; ping -I vr$n -c 3 -i 0.2 -W 1 -q $(ip_of 3) | tail -1
done
echo "  leaf1 의 VNI $VNI 원격 VTEP: $(dx leaf1 vtysh -c "show evpn vni $VNI" | awk '/Remote VTEPs/{f=1;next} f&&/^ *10\./{printf "%s ", $1}')"
echo "  MTU: xg1 $(cat /sys/class/net/xg1/mtu)  leaf1 vni $(dx leaf1 cat /sys/class/net/vni$VNI/mtu)  leaf1 eth1 $(dx leaf1 cat /sys/class/net/eth1/mtu)  RoCE active_mtu $(T ibv_devinfo -d rxe_x1 | awk '/active_mtu/{print $2}')"
ping -I vr1 -M do -s 8900 -c 1 -W 1 -q $(ip_of 3) >/dev/null && echo "  8900B DF ping g1→g3 통과 (VXLAN 오버헤드 포함 MTU 여유 확인)"
