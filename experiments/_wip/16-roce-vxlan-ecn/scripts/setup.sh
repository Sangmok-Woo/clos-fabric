#!/usr/bin/env bash
# 16번 준비. 여러 번 돌려도 같은 상태가 된다 (멱등). 되돌리기는 teardown.sh
#  1) 커널 모듈: dctcp, red/htb, pedit/csum/flower
#  2) leaf2·leaf4 에도 VNI 10010 을 만들고 송신 서버 x2·x4 를 붙인다 → 송신 v1·x2·x4 (리프 셋) → 수신 v3 (leaf3)
#  3) 서버 MTU 1500 (vxlan 장치가 1500 이라 9500 이면 큰 프레임이 브리지에서 버려진다 — 이 장은 MTU 실험이 아니다)
#  4) 서버 TCP: ECN 협상 켜고 송신은 DCTCP
#  5) 경로 고정: spine2 ↔ leaf3 링크를 내려 leaf3 로 가는 길을 spine1 하나로
#  6) 병목: spine1 eth3 (→ leaf3) 에 100Mbit + RED/ECN
# 트랙 A 의 rxe 서버(e1·e3)는 rxe-track.sh 가 따로 만든다 (rxe 가 커널을 멈춘 적이 있어 본 측정과 떼어 놓았다)
set -e
. "$(dirname "$0")/common.sh"

say "1) 모듈"
for m in tcp_dctcp sch_red sch_htb act_pedit act_csum cls_flower; do modprobe $m; done
echo "  ok"

say "2) leaf2·leaf4 VNI + 송신 서버 x2·x4"
for pair in "leaf2 10.255.1.2 65012" "leaf4 10.255.1.4 65014"; do
  set -- $pair; L=$1; VTEP=$2; AS=$3
  dx $L sh -c "ip link show $BR >/dev/null 2>&1 || {
      ip link add $BR type bridge; ip link set $BR type bridge stp_state 0; ip link set $BR up
      ip link add $VX type vxlan id $VNI dstport 4789 local $VTEP nolearning
      ip link set $VX master $BR; ip link set $VX up
      bridge link set dev $VX neigh_suppress on learning off; }"
  dx $L vtysh -c "conf t" -c "router bgp $AS" -c "address-family l2vpn evpn" -c "advertise-all-vni" >/dev/null
done
for x in x2 x4; do
  L=${LEAF[$x]}
  if ! docker ps --format '{{.Names}}' | grep -qx "$(c $x)"; then
    docker rm -f "$(c $x)" >/dev/null 2>&1 || true
    docker run -d --name "$(c $x)" --dns 8.8.8.8 alpine:3 sleep infinity >/dev/null
  fi
  dx $x sh -c 'command -v iperf3 && command -v ethtool' >/dev/null || dx $x apk add -q --no-progress iperf3 ethtool
  if ! nsx $x ip link show eth1 >/dev/null 2>&1; then
    ip link add tmp-$x type veth peer name tmpl-$x
    ip link set tmp-$x netns "$(pid $x)"; nsx $x ip link set tmp-$x name eth1
    ip link set tmpl-$x netns "$(pid $L)"; nsx $L ip link set tmpl-$x name eth4
    nsx $L ip link set eth4 master $BR; nsx $L ip link set eth4 up
    nsx $x ip addr add ${IPOF[$x]}/24 dev eth1; nsx $x ip link set eth1 up
  fi
done
# v1·v3 는 기본 경로가 없다. 설치하는 동안만 관리망(eth0)으로 내보낸다
# (lab.sh 의 apk_add 는 이 배포에서 관리망 게이트웨이를 못 읽어 빈 값이 된다)
MGW=$(dx v1 ip -4 addr show eth0 | awk '/inet /{split($2,a,"."); print a[1]"."a[2]"."a[3]".1"; exit}')
for h in v1 v3; do
  dx $h sh -c 'command -v iperf3 && command -v ethtool' >/dev/null && continue
  dx $h sh -c "echo nameserver 8.8.8.8 > /etc/resolv.conf; ip route replace default via $MGW dev eth0;
               apk add -q --no-progress iperf3 ethtool; rc=\$?; ip route del default; exit \$rc"
done
echo "  x2 → leaf2:eth4, x4 → leaf4:eth4 (VNI $VNI)"

say "3) 서버 MTU 1500"
for h in v1 v3 x2 x4; do nsx $h ip link set eth1 mtu 1500; done
# veth 는 64KB GSO 덩어리를 그대로 넘긴다 → 병목 RED 가 패킷 하나가 아니라 덩어리 단위로 마킹·드랍한다. 서버에서 잘라 보낸다
# (WSL 에는 ethtool 이 없어 서버 안의 것을 쓴다)
for h in v1 v3 x2 x4; do docker exec --privileged "$(c $h)" ethtool -K eth1 tso off gso off gro off; done
echo "  서버 eth1 tso/gso: $(docker exec "$(c v1)" ethtool -k eth1 | awk '/^(tcp-segmentation-offload|generic-segmentation-offload):/{printf "%s ", $2}')"
echo "  $(dx leaf1 ip -o link show $VX | grep -o 'mtu [0-9]*') (vxlan) / 서버 1500 / 언더레이 9500"

say "4) 서버 TCP"
# 컨테이너 netns 는 기본 netns 의 허용 목록에 있는 알고리즘만 고를 수 있다 (아니면 EPERM)
A=$(sysctl -n net.ipv4.tcp_allowed_congestion_control)
[ -f "$STATE/allowed_cc" ] || echo "$A" > "$STATE/allowed_cc"
case " $A " in *" dctcp "*) ;; *) sysctl -qw net.ipv4.tcp_allowed_congestion_control="$A dctcp" ;; esac
for h in v1 x2 x4 v3; do nsx $h sysctl -qw net.ipv4.tcp_ecn=1; done
# 수신도 DCTCP 여야 한다. 리눅스 DCTCP 는 SYN 에도 ECT 를 싣는데, cubic 수신측은 ECT 가 붙은 SYN 을 보면
# (RFC 3168: SYN 은 Not-ECT) 중간 장비가 망가졌다고 보고 ECN 협상을 거절한다 → 송신은 dctcp-reno 로 떨어진다
for h in $SENDERS $RX; do nsx $h sysctl -qw net.ipv4.tcp_congestion_control=dctcp; done
echo "  송수신 $(for h in $SENDERS $RX; do nsx $h sysctl -n net.ipv4.tcp_congestion_control; done | sort -u | tr '\n' ' ')/ tcp_ecn=1"

say "5) 경로 고정 (spine2 eth3 down)"
nsx spine2 ip link set eth3 down
sleep 4
for l in leaf1 leaf2 leaf4; do echo "  $l → 10.255.1.3: $(dx $l ip route get 10.255.1.3 | grep -o 'dev eth[0-9]*')"; done

say "6) 병목: spine1 eth3 → leaf3 ($RATE, RED/ECN)"
bn_on $BN_SPINE
nsx spine1 tc qdisc show dev eth3 | sed 's/^/  /'

say "확인: 송신 → 수신 ping"
for h in $SENDERS; do echo "  $h → v3 $(dx $h ping -c 2 -W 1 -q $RX_IP | tail -1)"; done
