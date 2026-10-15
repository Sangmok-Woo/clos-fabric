#!/usr/bin/env bash
# 실험 18 이 바꾼 것을 전부 되돌리고 패브릭 상태(BGP·EVPN·호스트 ping)를 다시 잰다 (멱등).
# rxe 커널 모듈은 남긴다 (실험 12·13 과 같이 쓴다).
set -u
. "$(dirname "$0")/common.sh"

say "1) 돌고 있는 도구 정리"
pkill -TERM -f 'run2/scripts/(dcqcn|sampler).py' 2>/dev/null; sleep 1
pkill -9 -f 'run2/scripts/(dcqcn|sampler).py' 2>/dev/null
pkill -9 -f 'ib_write_bw -d rxe_x' 2>/dev/null; pkill -9 -f 'iperf3 .*530[0-9]' 2>/dev/null
for p in $(pgrep -f "tcpdump .*18-roce-vxlan-ecn"); do kill $p 2>/dev/null; done

say "2) tc (병목·장애·계수기)"
decap_fault_off; encap_fault_off; counters_off
bneck_off spine1 eth3; bneck_off spine2 eth3; bneck_off leaf3 eth6
for n in 1 2 3 4; do for d in eth1 eth2; do nsx leaf$n tc qdisc del dev $d clsact 2>/dev/null; done; done
for n in 1 2 3 4; do tc qdisc del dev xg$n root 2>/dev/null; done
# step1.sh 가 바꿨을 수 있는 vxlan tos 를 기본값(0)으로
for n in 1 2 3 4; do dx leaf$n ip link set vni$VNI type vxlan tos 0 2>/dev/null; done

say "3) 경로 고정 해제 — spine2:eth3 올림"
if [ -f "$ST/spine2-eth3-down" ]; then nsx spine2 ip link set eth3 up; rm -f "$ST/spine2-eth3-down"; fi

say "4) g1~g4 · rxe_x · VNI 확장 · MTU"
for n in 1 2 3 4; do
  T rdma link del rxe_x$n 2>/dev/null
  ip link del xg$n 2>/dev/null; ip link del vr$n 2>/dev/null
done
for n in 2 4; do
  if [ -f "$ST/vni-leaf$n" ]; then
    dx leaf$n vtysh -c "conf t" -c "router bgp 6501$n" -c "address-family l2vpn evpn" -c "no advertise-all-vni" >/dev/null
    dx leaf$n ip link del vni$VNI; dx leaf$n ip link del br$VNI
    rm -f "$ST/vni-leaf$n"
  fi
done
for n in 1 3; do
  m=1500; [ -f "$ST/mtu-leaf$n" ] && m=$(cat "$ST/mtu-leaf$n")
  dx leaf$n ip link set vni$VNI mtu $m; dx leaf$n ip link set br$VNI mtu $m
done
rm -f "$ST"/mtu-leaf*
ip addr del $OOB/32 dev lo 2>/dev/null
if [ -f "$ST/l3mdev" ]; then
  { read t; read u; } < "$ST/l3mdev"
  sysctl -qw net.ipv4.tcp_l3mdev_accept=$t net.ipv4.udp_l3mdev_accept=$u; rm -f "$ST/l3mdev"
fi
if [ -f "$ST/tcp" ]; then
  { read e; read c; } < "$ST/tcp"
  sysctl -qw net.ipv4.tcp_ecn=$e net.ipv4.tcp_congestion_control=$c; rm -f "$ST/tcp"
fi
ip rule del pref 1000 l3mdev 2>/dev/null   # VRF 를 처음 만들 때 커널이 넣은 규칙
docker rm -f rtool >/dev/null 2>&1

say "5) 패브릭 상태 재확인"
for i in $(seq 60); do
  e=$(dx spine2 vtysh -c "show bgp summary json" | python3 -c 'import json,sys; d=json.load(sys.stdin)["ipv4Unicast"]["peers"]; print(sum(p["state"]=="Established" for p in d.values()))')
  [ "$e" = 4 ] && break; sleep 2
done
for n in spine1 spine2 leaf1 leaf2 leaf3 leaf4; do
  dx $n vtysh -c "show bgp summary json" | python3 -c "
import json,sys; d=json.load(sys.stdin)
for af in ('ipv4Unicast','l2VpnEvpn'):
    p=d.get(af,{}).get('peers',{})
    print('  $n', af, sum(v['state']=='Established' for v in p.values()), '/', len(p))"
done
echo "  leaf1 VNI $VNI 원격 VTEP: $(dx leaf1 vtysh -c "show evpn vni $VNI" | awk '/Remote VTEPs/{f=1;next} f&&/^ *10\./{printf "%s ", $1}')"
echo "  leaf1 → leaf3 VTEP 경로: $(dx leaf1 ip route show 10.255.1.3 | tr '\n' ' ')"
printf "  v1 → v3 (EVPN): "; dx v1 ping -c 3 -W 2 -q 10.10.10.33 | grep 'packet loss'
for h in 172.16.12.10 172.16.13.10 172.16.14.10; do printf "  h1 → %s: " $h; dx h1 ping -c 2 -W 2 -q $h | grep 'packet loss'; done
echo "  남은 tc: spine1 eth3 [$(nsx spine1 tc qdisc show dev eth3 | grep -vE 'noqueue' | head -1)]  leaf3 eth1 [$(nsx leaf3 tc qdisc show dev eth1 | grep -vE 'noqueue' | head -1)]"
echo "  ip rule: $(ip rule | tr '\n' ';' | cut -c1-200)"
