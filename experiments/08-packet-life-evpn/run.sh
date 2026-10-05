#!/usr/bin/env bash
# 실험 08 — 패킷의 일생: 주소록(EVPN)에서 배달(VXLAN)까지, 그리고 순수 L3와의 비교.
#   EVPN 경로: v1(leaf1, 10.10.10.11) ↔ v3(leaf3, 10.10.10.33), VNI 10010
#   순수 L3:   h1(leaf1, 172.16.11.10) ↔ h3(leaf3, 172.16.13.10), 같은 리프·같은 스파인을 라우팅만으로
# Part A  주소록: Type-3만 있는 상태 → v3가 말하는 순간의 Type-2 UPDATE → 커널 fdb 로 내려오는 것
# Part B  패킷의 일생: 네 지점(출발·포장 직후·허브 통과·도착)에서 같은 ping 을 따라간다
# Part C  효용(C-1 L2 확장, C-2 이사, C-3 멀티테넌시, C-4 ARP 억제)과
#         비용(C-5 상자 무게, C-6 오버레이만 죽는 장애, C-7 기억할 양)
# 바꾼 것은 끝에서 전부 되돌린다 (restore.sh 도 같은 일을 한다).
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=160
ST=$HERE/state; rm -rf "$CAPDIR" "$ST"; mkdir -p "$CAPDIR" "$ST"
exec > >(tee "$CAPDIR/run-output.txt") 2>&1
V3MAC=$(dx v3 cat /sys/class/net/eth1/address); V1MAC=$(dx v1 cat /sys/class/net/eth1/address)
echo "v1 $V1MAC / v3 $V3MAC"
vt() { dx "$1" vtysh -c "$2"; }
loss() { grep -o '[0-9]*% packet loss'; }
evpn_adv() { dx leaf3 vtysh -c "conf t" -c "router bgp 65013" -c "address-family l2vpn evpn" -c "$1advertise-all-vni" >/dev/null; }
bgp_est() { vt leaf1 "show ip bgp summary json" | python3 -c 'import json,sys; p=json.load(sys.stdin)["ipv4Unicast"]["peers"]; print(sum(1 for x in p.values() if x["state"]=="Established"), "/", len(p))'; }
arps_known() { vt leaf1 "show evpn vni 10010" | grep -o 'ARPs.*known for this VNI: [0-9]*' | grep -o '[0-9]*$'; }

# ─────────────────────────────── Part A
say "A-1 아무도 말하기 전 — v1·v3 의 MAC 을 지우고 본 주소록"
dx v1 ip neigh flush dev eth1; dx v3 ip neigh flush dev eth1
dx leaf3 bridge fdb del "$V3MAC" dev eth4 master 2>/dev/null
dx leaf1 bridge fdb del "$V1MAC" dev eth4 master 2>/dev/null
sleep 3
vt leaf1 "show evpn vni 10010" | grep -E "VNI:|Local VTEP|Remote VTEP|10\.255|Number of"
echo "  -- Type-3 (이 VNI 의 BUM 을 받겠다는 VTEP 목록) --"
vt leaf1 "show bgp l2vpn evpn route type multicast" | grep "\[3\]"
echo "  -- Type-2 (MAC 명부) --"
vt leaf1 "show bgp l2vpn evpn route type macip" | grep "\[2\]" || echo "  (비어 있음)"

say "A-2 v3 가 한 번 말하는 순간 — leaf1 에 도착하는 Type-2 UPDATE 캡처"
SNAP=0 cap_start a2-leaf1-bgp leaf1 any tcp port 179
cap_wait 2
dx v3 ping -c 1 -W 1 10.10.10.11 >/dev/null
sleep 3
cap_stop >/dev/null
vt leaf1 "show bgp l2vpn evpn route type macip" | grep "\[2\]"

say "A-3 명부가 커널 배달 표로 내려온 것"
echo "  leaf1 bridge fdb (vni10010): $(dx leaf1 bridge fdb show dev vni10010 | grep -i "$V3MAC")"

# ─────────────────────────────── Part B
say "B 패킷의 일생 — v1 → v3 ping 5개, 여섯 지점 동시 캡처"
dx v1 ip neigh flush dev eth1
for p in "v1 eth1" "leaf1 eth1" "leaf1 eth2" "leaf3 eth1" "leaf3 eth2" "v3 eth1"; do
  set -- $p
  cap_start "b-$1-$2" "$1" "$2" icmp or arp or udp port 4789
done
cap_wait 1
dx v1 ping -c 5 -i 0.2 -q 10.10.10.33 | tail -2
cap_stop
echo "  -- leaf1 머릿속 --"
echo "  bridge fdb (v3 MAC): $(dx leaf1 bridge fdb show br br10010 | grep -i "$V3MAC" | tr '\n' ' ')"
echo "  ip route get 10.255.1.3: $(dx leaf1 ip route get 10.255.1.3 | head -1)"
vt leaf1 "show ip route 10.255.1.3" | grep -E "via" | sed 's/^/    /'

# ─────────────────────────────── Part C 효용
say "C-1 L2 확장 — 같은 서브넷을 두 랙에"
echo "  EVPN   : v1(leaf1) → v3(leaf3), 둘 다 10.10.10.0/24 : $(dx v1 ping -c 3 -W 1 -q 10.10.10.33 | loss)"
dx h3 ip addr add 172.16.11.50/24 dev eth1
echo "  순수 L3 : h3(leaf3)에 h1 과 같은 서브넷 주소 172.16.11.50 → h1 : $(dx h3 ping -c 3 -W 1 -q -I 172.16.11.50 172.16.11.10 | loss)"
echo "    h3 가 본 h1 이웃: $(dx h3 ip neigh show 172.16.11.10)"
dx h3 ip addr del 172.16.11.50/24 dev eth1

say "C-2 이사 — v3 를 leaf3 에서 leaf1 로 (MAC·IP 그대로)"
SNAP=0 cap_start c2-leaf1-bgp leaf1 any tcp port 179
cap_start c2-v1-eth1 v1 eth1 icmp or arp
cap_wait 1
( dx v1 ping -i 0.05 -c 160 -W 1 10.10.10.33 > "$ST/c2-ping" 2>&1 ) & PINGPID=$!
sleep 2
echo "c2 $(date +%s.%N)" >> "$ST/timeline"
dx v3 ip link set eth1 down
ip netns add mob 2>/dev/null; ip link add mobh type veth peer name mobl
ip link set mobl netns "$(pid leaf1)"; ip link set mobh netns mob
dx leaf1 sh -c 'ip link set mobl master br10010; ip link set mobl up'
ip netns exec mob sh -c "ip link set mobh address $V3MAC; ip link set mobh mtu 1500; ip addr add 10.10.10.33/24 dev mobh; ip link set lo up; ip link set mobh up"
ip netns exec mob ping -c 1 -W 1 10.10.10.11 >/dev/null   # 새 자리에서 한마디 → leaf1 이 로컬로 배운다
wait $PINGPID
cap_stop >/dev/null
echo "  v1 의 ping (0.05초 간격 160개): $(grep -o '[0-9]* packets transmitted, [0-9]* packets received' "$ST/c2-ping")"
vt leaf1 "show evpn mac vni 10010 mac $V3MAC" | grep -E "Intf|Remote|Seq|Local" | tr -s ' ' | sed 's/^/    /'
ip netns del mob; dx v3 ip link set eth1 up; sleep 3
dx v3 ping -c 1 -W 2 10.10.10.11 >/dev/null; sleep 3
echo "  원래 자리로 돌아온 뒤:"; vt leaf1 "show evpn mac vni 10010 mac $V3MAC" | grep -E "Remote|Seq" | tr -s ' ' | sed 's/^/    /'

say "C-3 멀티테넌시 — VNI 10020(B사)에 같은 10.10.10.0/24, 같은 IP"
mk_tenant() {   # mk_tenant <리프> <VTEP> <netns> <IP>
  local leaf=$1 vtep=$2 ns=$3 ip=$4
  dx "$leaf" sh -c "ip link add br10020 type bridge; ip link set br10020 type bridge stp_state 0; ip link set br10020 up
    ip link add vni10020 type vxlan id 10020 dstport 4789 local $vtep nolearning
    ip link set vni10020 master br10020; ip link set vni10020 up
    bridge link set dev vni10020 neigh_suppress on learning off"
  ip netns add "$ns"; ip link add "${ns}h" type veth peer name "${ns}l"
  ip link set "${ns}l" netns "$(pid "$leaf")"; ip link set "${ns}h" netns "$ns"
  dx "$leaf" sh -c "ip link set ${ns}l master br10020; ip link set ${ns}l up"
  ip netns exec "$ns" sh -c "ip link set ${ns}h mtu 1500; ip addr add $ip/24 dev ${ns}h; ip link set ${ns}h up"
}
mk_tenant leaf1 10.255.1.1 tb1 10.10.10.11
mk_tenant leaf3 10.255.1.3 tb3 10.10.10.33
sleep 6
cap_start c3-leaf1-eth1 leaf1 eth1 udp port 4789
cap_start c3-leaf1-eth2 leaf1 eth2 udp port 4789
cap_wait 1
echo "  B사 tb1 → tb3 (10.10.10.11 → 10.10.10.33, VNI 10020): $(ip netns exec tb1 ping -c 3 -W 1 -q 10.10.10.33 | loss)"
echo "  A사 v1  → v3  (10.10.10.11 → 10.10.10.33, VNI 10010): $(dx v1 ping -c 3 -W 1 -q 10.10.10.33 | loss)"
cap_stop >/dev/null
echo "  같은 10.10.10.33 의 MAC — A사 v1 이 본 것: $(dx v1 ip neigh show 10.10.10.33 | awk '{print $5}') / B사 tb1 이 본 것: $(ip netns exec tb1 ip neigh show 10.10.10.33 | awk '{print $5}')"
vt leaf1 "show evpn vni" | grep -E "^ *100[12]0" | tr -s ' ' | sed 's/^/    /'
for n in tb1 tb3; do ip netns del $n; done
for l in leaf1 leaf3; do dx $l sh -c 'ip link del vni10020; ip link del br10020'; done

say "C-4 외침 줄이기 — v1 이 v3 를 ARP 로 물을 때 패브릭으로 나가는 ARP 수"
arp_round() {   # arp_round <이름>: v1 이 ARP 를 3번 일으키고, leaf1 업링크에서 VXLAN 안의 ARP 요청을 센다
  cap_start "c4-$1-eth1" leaf1 eth1 udp port 4789
  cap_start "c4-$1-eth2" leaf1 eth2 udp port 4789
  cap_wait 1
  for k in 1 2 3; do dx v1 ip neigh flush dev eth1; dx v1 ping -c 1 -W 1 10.10.10.33 >/dev/null; sleep 0.3; done
  cap_stop >/dev/null
  local n=0 f
  for f in "$CAPDIR/c4-$1-eth1.pcap" "$CAPDIR/c4-$1-eth2.pcap"; do
    n=$(( n + $(tcpdump -nn -r "$f" 2>/dev/null | grep -c "ARP, Request") ))
  done
  echo "  $1: 패브릭으로 나간 ARP 요청 $n개 (v1 이 ARP 를 3번 일으킴)"
}
dx leaf1 bridge link set dev vni10010 neigh_suppress off
arp_round off
dx leaf1 bridge link set dev vni10010 neigh_suppress on
arp_round on-noip
echo "    이때 leaf1 이 아는 ARP(IP↔MAC) 수: $(arps_known)"
# 리프 브리지에 IP 를 주면 커널이 이웃(IP↔MAC)을 배우고, EVPN 이 MAC/IP 를 함께 광고한다
dx leaf1 ip addr add 10.10.10.201/24 dev br10010
dx leaf3 ip addr add 10.10.10.203/24 dev br10010
dx leaf3 ping -c 1 -W 1 10.10.10.33 >/dev/null; dx leaf1 ping -c 1 -W 1 10.10.10.11 >/dev/null; sleep 4
echo "    리프 브리지에 IP 를 준 뒤 leaf1 이 아는 ARP 수: $(arps_known)"
vt leaf1 "show bgp l2vpn evpn route type macip" | grep "\[32\]" | sed 's/^/    /'
arp_round on-withip
dx leaf1 ip addr del 10.10.10.201/24 dev br10010
dx leaf3 ip addr del 10.10.10.203/24 dev br10010
cap_start c4-l3-eth1 leaf1 eth1 arp or udp port 4789
cap_start c4-l3-eth2 leaf1 eth2 arp or udp port 4789
cap_wait 1
for k in 1 2 3; do dx h1 ip neigh flush dev eth1; dx h1 ping -c 1 -W 1 172.16.13.10 >/dev/null; sleep 0.3; done
cap_stop >/dev/null
echo "  순수 L3: h1 이 ARP 를 3번 일으키는 동안 leaf1 업링크의 ARP: $(cat "$CAPDIR"/c4-l3-eth*.pcap | tcpdump -nn -r - 2>/dev/null | grep -c ARP)개 (h1 은 게이트웨이만 묻는다)"

# ─────────────────────────────── Part C 비용
say "C-5 상자 무게 — 같은 1472B ping 의 프레임 크기, 그리고 처리량"
cap_start c5-v1-eth1 v1 eth1 icmp
cap_start c5-leaf1-eth1 leaf1 eth1 udp port 4789
cap_start c5-leaf1-eth2 leaf1 eth2 udp port 4789
cap_wait 1
dx v1 ping -c 2 -s 1472 -W 1 -q 10.10.10.33 >/dev/null
cap_stop >/dev/null
echo "  v1 이 낸 프레임: $(tcpdump -nn -e -r "$CAPDIR/c5-v1-eth1.pcap" 2>/dev/null | grep -m1 'echo request' | grep -o 'length [0-9]*' | head -1)"
echo "  스파인 쪽 링크의 프레임: $(for f in "$CAPDIR"/c5-leaf1-eth*.pcap; do tcpdump -nn -e -r "$f" 2>/dev/null; done | grep -m1 'length' | grep -o 'length [0-9]*' | head -1)"
for s in v3 h3; do dx $s sh -c "pkill iperf3; nohup iperf3 -s >/dev/null 2>&1 &"; done
sleep 1
# 기본 MTU 그대로: 서버 NIC 는 9500, 리프의 VXLAN 장치(vni10010)와 브리지는 1500
echo "  기본 MTU (v1·v3 $(dx v1 cat /sys/class/net/eth1/mtu), leaf1 vni10010 $(dx leaf1 cat /sys/class/net/vni10010/mtu)): EVPN-VXLAN TCP $(dx v1 iperf3 -c 10.10.10.33 -t 3 -f m 2>/dev/null | awk '/receiver/{print $7}') Mbit/s"
for h in v1 v3 h1 h3; do echo "$h $(dx $h cat /sys/class/net/eth1/mtu)"; done > "$ST/hmtu"
for h in v1 v3 h1 h3; do dx $h ip link set eth1 mtu 1500; done     # 같은 조건(MTU 1500)에서 비교
for r in 1 2 3; do
  ev=$(dx v1 iperf3 -c 10.10.10.33 -t 4 -f m 2>/dev/null | awk '/receiver/{print $7}')
  l3=$(dx h1 iperf3 -c 172.16.13.10 -t 4 -f m 2>/dev/null | awk '/receiver/{print $7}')
  echo "  TCP 처리량 $r회: EVPN-VXLAN ${ev} Mbit/s · 순수 L3 ${l3} Mbit/s"
done
for s in v3 h3; do dx $s pkill iperf3; done
while read -r h m; do dx $h ip link set eth1 mtu "$m"; done < "$ST/hmtu"

say "C-6 고장 지점 증가 — 언더레이는 살려 두고 leaf3 의 EVPN 광고만 끈다"
SNAP=0 cap_start c6-leaf1-bgp leaf1 any tcp port 179
cap_wait 1
evpn_adv "no "; sleep 5
echo "  BGP IPv4 세션 (leaf1): $(bgp_est)"
echo "  순수 L3 h1 → h3: $(dx h1 ping -c 3 -W 1 -q 172.16.13.10 | loss)"
echo "  EVPN   v1 → v3: $(dx v1 ping -c 3 -W 1 -q 10.10.10.33 | loss)"
echo "  leaf1 의 VNI 10010: $(vt leaf1 'show evpn vni' | grep -E '^ *10010' | tr -s ' ')"
evpn_adv ""; sleep 6
cap_stop >/dev/null
dx v3 ping -c 1 -W 2 10.10.10.11 >/dev/null
echo "  다시 켠 뒤 v1 → v3: $(dx v1 ping -c 3 -W 1 -q 10.10.10.33 | loss)"

say "C-7 기억해야 할 양 — leaf1 기준"
echo "  순수 L3: BGP IPv4 경로 $(vt leaf1 'show ip bgp summary json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["ipv4Unicast"]["ribCount"])')개, 커널 경로 $(dx leaf1 ip route | grep -vc '^[[:space:]]')줄"
vt leaf1 "show bgp l2vpn evpn" | grep -E "^ *\*" | awk '{print $2}' | sort | uniq -c | sed 's/^/    EVPN 경로 /'
echo "  EVPN: MAC 명부 $(vt leaf1 'show evpn mac vni 10010' | grep -c 'aa:'), vni10010 fdb $(dx leaf1 bridge fdb show dev vni10010 | wc -l)줄"

say "원복 확인"
for l in leaf1 leaf3; do dx $l ip -br addr show br10010 | tr -s ' '; done
dx leaf1 bridge -d link show dev vni10010 | grep -o "neigh_suppress [a-z]*"
for h in v1 v3 h1 h3; do echo "  $h mtu $(dx $h cat /sys/class/net/eth1/mtu)"; done
dx v1 ping -c 2 -W 1 -q 10.10.10.33 | tail -1
