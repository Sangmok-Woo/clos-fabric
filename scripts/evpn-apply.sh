#!/usr/bin/env bash
# 4단계: leaf1 / leaf3 에 VXLAN + BGP EVPN 을 얹어, 랙이 다른 v1·v3 를 같은 L2 에 놓는다.
#   v1 (leaf1 eth4) 10.10.10.11/24   ┐
#                                    ├ 같은 브로드캐스트 도메인(VNI 10010)
#   v3 (leaf3 eth4) 10.10.10.33/24   ┘
# 사용법: ./scripts/evpn-apply.sh
set -eu
VNI=10010
BR=br$VNI
VX=vni$VNI

echo "=== 1) 리프 안에 브리지 + VXLAN 터널 만들기 ==="
for pair in "leaf1 10.255.1.1" "leaf3 10.255.1.3"; do
  set -- $pair; N=$1; VTEP=$2
  docker exec clab-clos-$N sh -c "
    ip link add $BR type bridge 2>/dev/null || true
    ip link set $BR type bridge stp_state 0
    ip link set $BR up
    ip link add $VX type vxlan id $VNI dstport 4789 local $VTEP nolearning 2>/dev/null || true
    ip link set $VX master $BR
    ip link set $VX up
    ip link set eth4 master $BR
    ip link set eth4 up
    bridge link set dev $VX neigh_suppress on learning off 2>/dev/null || true
  "
  echo "  $N : $BR + $VX (VTEP $VTEP) 생성"
done

echo
echo "=== 2) BGP에 EVPN 주소군 켜기 ==="
# 스파인: EVPN 경로를 그냥 중계만 한다. next-hop 을 자기 것으로 바꾸면 터널이 깨지므로 그대로 둔다.
for pair in "spine1 65001" "spine2 65002"; do
  set -- $pair
  docker exec clab-clos-$1 vtysh -c "conf t" -c "router bgp $2" -c "address-family l2vpn evpn" \
    -c "neighbor FABRIC activate" -c "neighbor FABRIC attribute-unchanged next-hop" >/dev/null
  echo "  $1 : EVPN 중계 설정 (next-hop 유지)"
done
# 리프: 자기 VNI를 광고한다.
for pair in "leaf1 65011" "leaf3 65013"; do
  set -- $pair
  docker exec clab-clos-$1 vtysh -c "conf t" -c "router bgp $2" -c "address-family l2vpn evpn" \
    -c "neighbor FABRIC activate" -c "advertise-all-vni" >/dev/null
  echo "  $1 : EVPN 활성 + advertise-all-vni"
done
# leaf2/leaf4 는 VNI가 없지만, 세션은 열어둬야 나중에 랙을 추가할 때 설정이 같아진다.
for pair in "leaf2 65012" "leaf4 65014"; do
  set -- $pair
  docker exec clab-clos-$1 vtysh -c "conf t" -c "router bgp $2" -c "address-family l2vpn evpn" \
    -c "neighbor FABRIC activate" >/dev/null
done

# 세션이 이미 붙어 있는 상태에서 주소군을 새로 켜면 capability 재협상이 필요하다(=NoNeg).
# 소프트 클리어로는 안 되고 세션을 한 번 끊었다 붙여야 한다.
echo
echo "=== 3) BGP 세션 재기동 (새 주소군 협상) ==="
for n in spine1 spine2 leaf1 leaf2 leaf3 leaf4; do
  docker exec clab-clos-$n vtysh -c "clear bgp *" >/dev/null 2>&1
done
sleep 12
echo
echo "=== 4) 확인 ==="
echo "-- leaf1 이 아는 VNI (Remote VTEP 1 이어야 정상) --"
docker exec clab-clos-leaf1 vtysh -c "show evpn vni"
echo "-- v1 -> v3 (랙을 넘는 같은 서브넷 통신) --"
docker exec clab-clos-v1 ping -c 3 -W 2 10.10.10.33 || true
echo "-- leaf1 이 배운 MAC (원격 MAC 은 leaf3 루프백을 넥스트홉으로 갖는다) --"
docker exec clab-clos-leaf1 vtysh -c "show evpn mac vni $VNI"
