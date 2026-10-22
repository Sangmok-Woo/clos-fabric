#!/usr/bin/env bash
# 실험 15 구성. 베이스 패브릭(+ scripts/evpn-apply.sh) 위에 얹는다. 되돌리기는 restore.sh.
#   setup.sh            ESI-LAG: hmh 의 bond0 가 leaf1:eth5 · leaf2:eth5 에 한 줄씩, 두 리프 bond1 = 같은 ES
#   setup.sh single     대조군: ES 를 지우고 leaf2 쪽 줄을 내린다 (hmh 는 leaf1 에만 붙은 서버)
#   setup.sh uplink on|off   leaf1·leaf2 의 스파인 포트(eth1·eth2)에 evpn mh uplink 추적
set -u
. "$(dirname "$0")/common.sh"
MODE=${1:-esi}

es_on()  { vt "$1" "conf t" "interface bond1" "evpn mh es-id $ESID" "evpn mh es-sys-mac $ESMAC" >/dev/null; }
es_off() { vt "$1" "conf t" "interface bond1" "no evpn mh es-id" "no evpn mh es-sys-mac" >/dev/null 2>&1; }

case $MODE in
uplink)
  for n in leaf1 leaf2; do for p in eth1 eth2; do
    if [ "$2" = on ]; then vt $n "conf t" "interface $p" "evpn mh uplink" >/dev/null
    else vt $n "conf t" "interface $p" "no evpn mh uplink" >/dev/null; fi
  done; done
  echo "  uplink 추적 $2 (leaf1·leaf2 eth1·eth2)"; exit 0 ;;
single)
  es_off leaf1; es_off leaf2
  nsx leaf2 ip link set $PORT down
  sleep 3
  echo "  대조군: ES 없음, hmh 는 leaf1 에만"; exit 0 ;;
esi) ;;
*) echo "사용: setup.sh [esi|single|uplink on|off]"; exit 1 ;;
esac

mkdir -p "$ST"
say "1) 호스트 두 대와 배선"
host_up hmh; host_up hrem
wire leaf1 $PORT hmh eth1
wire leaf2 $PORT hmh eth2
wire leaf3 $PORT hrem eth1

# hmh: LACP bond. fast = LACPDU 1초, 3번 못 받으면 뺀다. layer3+4 해시로 흐름마다 다른 줄
if ! nsx hmh ip link show bond0 >/dev/null 2>&1; then
  nsx hmh ip link add bond0 type bond mode 802.3ad lacp_rate fast miimon 100 xmit_hash_policy layer3+4
  nsx hmh ip link set bond0 address $MHMAC
  for p in eth1 eth2; do nsx hmh ip link set $p down; nsx hmh ip link set $p master bond0; done
  nsx hmh ip addr add $MHIP/24 dev bond0
fi
nsx hmh ip link set bond0 up; nsx hmh ip link set eth1 up; nsx hmh ip link set eth2 up; nsx hmh ip link set lo up
nsx hrem ip link set eth1 address $RMMAC 2>/dev/null
nsx hrem ip addr replace $RMIP/24 dev eth1; nsx hrem ip link set eth1 up; nsx hrem ip link set lo up

say "2) 리프 브리지·VXLAN (VNI $VNI)"
for n in leaf1 leaf2 leaf3; do
  nsx $n ip link show $BR >/dev/null 2>&1 || nsx $n ip link add $BR type bridge stp_state 0
  nsx $n ip link set $BR up
  nsx $n ip link show $VX >/dev/null 2>&1 || nsx $n ip link add $VX type vxlan id $VNI dstport 4789 local "$(vtep_of $n)" nolearning
  nsx $n ip link set $VX master $BR; nsx $n ip link set $VX up
  nsx $n bridge link set dev $VX neigh_suppress on learning off
done
# leaf1·leaf2: 서버 포트를 bond1 로. 두 리프가 같은 ad_actor_system 을 내야 hmh 가 한 묶음으로 받는다
for n in leaf1 leaf2; do
  if ! nsx $n ip link show bond1 >/dev/null 2>&1; then
    nsx $n ip link add bond1 type bond mode 802.3ad lacp_rate fast miimon 100 ad_actor_system $ESMAC
    nsx $n ip link set $PORT down; nsx $n ip link set $PORT master bond1
    nsx $n ip link set bond1 master $BR
  fi
  nsx $n ip link set bond1 up; nsx $n ip link set $PORT up
done
nsx leaf3 ip link set $PORT master $BR; nsx leaf3 ip link set $PORT up

say "3) FRR: VNI $VNI RT $RT, ES $ESID / $ESMAC"
for n in leaf1 leaf2 leaf3; do
  vt $n "conf t" "router bgp $(as_of $n)" "address-family l2vpn evpn" "advertise-all-vni" \
     "vni $VNI" "route-target import $RT" "route-target export $RT" >/dev/null
done
es_on leaf1; es_on leaf2
echo "  완료. 상태 확인: run.sh step0"
