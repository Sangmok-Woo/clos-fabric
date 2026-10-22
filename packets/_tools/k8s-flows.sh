#!/usr/bin/env bash
# k8s-ceph 랩에서 경로별로 패킷을 보내고, 지나가는 곳마다 캡처한다. WSL root 에서 실행.
#   ./k8s-flows.sh            흐름 7개 전부 캡처 + 해독문
#   ./k8s-flows.sh prod-l2    하나만
#   ./k8s-flows.sh decode     해독문만 다시
# 결과: packets/<날짜>/raw/k8s-<흐름>__<노드>-<포트>.pcap (앞 256바이트), k8s-<흐름>.decode.txt
# 랩: ../../k8s-ceph/up.sh 로 먼저 올린다
#
# 캡처 위치: 출발 리프의 서버 포트(VLAN 태그) → 출발 리프 업링크 두 줄(VXLAN) → 도착 리프 업링크 → 도착 리프 서버 포트
# 리프·서버 컨테이너에는 tcpdump가 없어서 호스트(WSL)의 tcpdump를 nsenter로 노드 네트워크 안에서 돌린다
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
N=clab-clos
CAP=$ROOT/$(date +%F)/raw
SNAP=256
mkdir -p $CAP

pid() { docker inspect -f '{{.State.Pid}}' $N-$1; }
dx()  { local n=$1; shift; docker exec $N-$n "$@"; }

# cap <흐름> "<노드:포트> ..." <BPF>  → 백그라운드 tcpdump. stop 으로 끝낸다
PIDS=()
cap() {
  local flow=$1 points=$2; shift 2
  for p in $points; do
    local node=${p%%:*} ifc=${p##*:}
    rm -f $CAP/k8s-${flow}__$node-$ifc.pcap
    # nsenter 가 tcpdump 로 exec 되므로 $! 가 곧 tcpdump 다
    nsenter -t "$(pid $node)" -n tcpdump -i $ifc -s $SNAP -U -nn -w $CAP/k8s-${flow}__$node-$ifc.pcap "$@" >/dev/null 2>&1 &
    PIDS+=($!)
  done
  sleep 1   # tcpdump 가 붙을 시간
}
stop() {
  sleep 1   # 버퍼에 남은 패킷을 쓸 시간
  kill "${PIDS[@]}" 2>/dev/null; wait "${PIDS[@]}" 2>/dev/null; PIDS=()
}
up() { echo "leaf$1:eth1 leaf$1:eth2"; }   # 리프 업링크 두 줄
say() { printf '\n== %s\n' "$*"; }

flow_prod-l2() {
  say "1. PROD 같은 서브넷, 랙 넘기: wrk1(leaf1) → wrk3(leaf3) 10.10.16.23"
  # 이웃 표를 비워 ARP부터 보이게 한다. 리프가 EVPN으로 배운 MAC/IP로 대신 답하는지(neigh_suppress) 본다
  dx wrk1 ip neigh flush dev eth1.110
  cap prod-l2 "leaf1:eth11 $(up 1) $(up 3) leaf3:eth11" 'arp or icmp or (udp port 4789)'
  dx wrk1 ping -c 3 -i 0.2 -s 100 10.10.16.23
  stop
}
flow_storage() {
  say "2. STORAGE 점보: wrk1 스토리지 NIC(leaf1) → ceph3 Ceph public(leaf4) 10.10.20.33"
  cap storage "leaf1:eth12 $(up 1) $(up 4) leaf4:eth13" 'icmp or (udp port 4789)'
  dx wrk1 ping -c 3 -i 0.2 -M do -s 8972 10.10.20.33
  stop
}
flow_repl() {
  say "3. REPL 복제망: ceph3(leaf4) → ceph1(leaf2) 10.10.24.31"
  cap repl "leaf4:eth14 $(up 4) $(up 2) leaf2:eth14" 'icmp or (udp port 4789)'
  dx ceph3 ping -c 3 -i 0.2 -M do -s 8972 10.10.24.31
  stop
}
flow_vip() {
  say "4. PROD 라우팅(L3VNI): wrk1(leaf1) → Ingress VIP 10.10.32.10 (wrk2@leaf2 · wrk3@leaf3)"
  cap vip "leaf1:eth11 $(up 1) $(up 2) $(up 3) leaf2:eth11 leaf3:eth11" 'icmp or (udp port 4789)'
  dx wrk1 ping -c 3 -i 0.2 -s 100 10.10.32.10
  stop
}
flow_blocked() {
  say "5. 막힌 길: wrk1 노드망(eth1.110) → Ceph public 10.10.20.31 (VRF가 다름)"
  cap blocked "leaf1:eth11 $(up 1)" 'icmp or (udp port 4789)'
  dx wrk1 ping -c 2 -W 1 -I eth1.110 10.10.20.31
  stop
}
flow_k8s-bgp() {
  say "6. 워커 BGP: wrk2가 VIP를 철회했다가 다시 광고 (wrk2 ↔ leaf2, VLAN 110 위 eBGP)"
  cap k8s-bgp "leaf2:eth11" 'tcp port 179'
  dx wrk2 vtysh -c "conf t" -c "router bgp 65200" -c "address-family ipv4 unicast" -c "no network 10.10.32.10/32" >/dev/null
  sleep 3
  dx wrk2 vtysh -c "conf t" -c "router bgp 65200" -c "address-family ipv4 unicast" -c "network 10.10.32.10/32" >/dev/null
  sleep 3
  stop
}
flow_evpn() {
  say "7. EVPN 컨트롤플레인: 같은 순간 leaf2 → 스파인으로 나가는 Type-5 경로 철회·광고"
  cap evpn "$(up 2)" 'tcp port 179'
  dx wrk2 vtysh -c "conf t" -c "router bgp 65200" -c "address-family ipv4 unicast" -c "no network 10.10.32.10/32" >/dev/null
  sleep 3
  dx wrk2 vtysh -c "conf t" -c "router bgp 65200" -c "address-family ipv4 unicast" -c "network 10.10.32.10/32" >/dev/null
  sleep 3
  stop
}

# 해독문: 흐름마다 캡처 지점별로 묶는다. -e(이더넷·VLAN 헤더) -v(IP·UDP 길이, TTL, DF) -nn
decode() {
  cd $CAP
  for flow in $(ls k8s-*__*.pcap | sed 's/__.*//' | sort -u); do
    for f in ${flow}__*.pcap; do
      echo "### $(basename $f .pcap | sed 's/.*__//')   ($(tcpdump -nn -tt -r $f 2>/dev/null | grep -c "^[0-9]") 패킷)"
      tcpdump -nn -e -v -tttt -r $f 2>/dev/null | sed 's/^[0-9-]* //'
      echo
    done > $flow.decode.txt
  done
}

FLOWS="prod-l2 storage repl vip blocked k8s-bgp evpn"
if [ "${1:-}" = decode ]; then decode; exit; fi
for f in ${1:-$FLOWS}; do flow_$f; done
decode

echo; echo "== 캡처 파일"
for f in $CAP/k8s-*.pcap; do printf "  %-44s %4s 패킷
" "$(basename $f)" "$(tcpdump -nn -tt -r $f 2>/dev/null | grep -c "^[0-9]")"; done
