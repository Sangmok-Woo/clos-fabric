#!/bin/sh
# 리프 데이터플레인: VRF 3개(L3VNI) + VLAN 브리지 3개(L2VNI, 애니캐스트 게이트웨이)
# 리프 안에서 실행한다: sh /k8s/overlay.sh <VTEP 루프백>
# 베이스 설정(언더레이·eth3/eth4 서버 포트)은 건드리지 않고 eth11~eth14만 쓴다
#
#   VLAN 110 K8S-NODE  10.10.16.0/24  MTU 1500  VRF PROD     ← 워커 eth1
#   VLAN 120 STORAGE   10.10.20.0/24  MTU 9000  VRF STORAGE  ← 워커 eth2, Ceph eth1 (Ceph public)
#   VLAN 130 REPL      10.10.24.0/24  MTU 9000  VRF REPL     ← Ceph eth2 (Ceph cluster, 복제 전용)
set -e
VTEP=$1
sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0

# VRF마다 L3VNI 하나 (대칭형 IRB: 다른 서브넷 사이 라우팅은 이 VNI로 넘어간다)
l3vni() {  # $1 VRF $2 테이블 $3 VNI
  ip link add $1 type vrf table $2
  ip link set $1 up
  ip link add br$3 type bridge stp_state 0
  ip link set br$3 master $1 addrgenmode none
  ip link add vx$3 type vxlan id $3 local $VTEP dstport 4789 nolearning
  ip link set vx$3 master br$3 mtu 9000 addrgenmode none
  ip link set vx$3 up
  ip link set br$3 mtu 9000 up
}
l3vni PROD 10 50010
l3vni STORAGE 20 50020
l3vni REPL 30 50030

# VLAN마다 브리지 + L2VNI + 애니캐스트 게이트웨이 (모든 리프가 같은 IP/MAC)
vlan() {  # $1 VLAN $2 VRF $3 MTU $4 게이트웨이 $5.. 서버 포트
  V=$1 VRF=$2 MTU=$3 GW=$4; shift 4
  ip link add br$V type bridge stp_state 0
  ip link set br$V address 00:00:5e:00:01:01 master $VRF
  ip link add vx10$V type vxlan id 10$V local $VTEP dstport 4789 nolearning
  ip link set vx10$V mtu $MTU master br$V addrgenmode none
  bridge link set dev vx10$V neigh_suppress on learning off
  ip link set vx10$V up
  for p in "$@"; do
    [ -e /sys/class/net/$p ] || continue      # 이 랙에 없는 서버 쪽 포트
    ip link set $p up
    ip link add link $p name $p.$V type vlan id $V
    ip link set $p.$V mtu $MTU master br$V up
  done
  ip link set br$V mtu $MTU up
  ip addr add $GW dev br$V
}
vlan 110 PROD    1500 10.10.16.1/24 eth11
vlan 120 STORAGE 9000 10.10.20.1/24 eth12 eth13
vlan 130 REPL    9000 10.10.24.1/24 eth14
echo "$(hostname): VRF 3개, VLAN 110/120/130 (VTEP $VTEP)"
