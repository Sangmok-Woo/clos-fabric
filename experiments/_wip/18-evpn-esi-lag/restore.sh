#!/usr/bin/env bash
# 실험 18 을 걷어 내고 베이스 패브릭(+ evpn-apply.sh) 상태로 되돌린다. run.sh 가 중간에 멈췄을 때도 이것.
. "$(dirname "$0")/common.sh"
pkill -f "$HERE/watch.sh" 2>/dev/null; pkill -f "$HERE/probe.py" 2>/dev/null
for d in "$HERE"/capture/*/r1 "$HERE"/capture/step1; do [ -f "$d/.pids" ] && xargs -r kill < "$d/.pids" 2>/dev/null; rm -f "$d/.pids"; done

# 주입이 남아 있을 수 있는 leaf1 포트를 올린다
printf 'link set %s up\n' eth1 eth2 eth3 eth4 | nsx leaf1 ip -batch - 2>/dev/null

for n in leaf1 leaf2; do
  vt $n "conf t" "interface eth1" "no evpn mh uplink" "interface eth2" "no evpn mh uplink" >/dev/null 2>&1
  vt $n "conf t" "interface bond1" "no evpn mh es-id" "no evpn mh es-sys-mac" >/dev/null 2>&1
done
for n in leaf1 leaf2 leaf3; do
  vt $n "conf t" "router bgp $(as_of $n)" "address-family l2vpn evpn" "no vni $VNI" >/dev/null 2>&1
  nsx $n ip link del bond1 2>/dev/null; nsx $n ip link del $VX 2>/dev/null; nsx $n ip link del $BR 2>/dev/null
  vt $n "conf t" "no interface bond1" >/dev/null 2>&1
done
# leaf2 는 원래 advertise-all-vni 가 없다 (evpn-apply.sh 는 leaf1·leaf3 에만)
vt leaf2 "conf t" "router bgp $(as_of leaf2)" "address-family l2vpn evpn" "no advertise-all-vni" >/dev/null 2>&1
# 호스트 컨테이너를 지우면 netns 와 함께 veth 양 끝(리프 eth5)도 사라진다
docker rm -f "$(c hmh)" "$(c hrem)" >/dev/null 2>&1
sleep 2
echo "  남은 것: $(for n in leaf1 leaf2 leaf3; do nsx $n ip -br link | grep -cE "^(bond1|$BR|$VX|$PORT)"; done | paste -sd+ | bc) 개 (0 이어야 정상)"
echo "  v1 → v3: $(dx v1 ping -c 2 -W 1 10.10.10.33 | grep -o '[0-9]* packets received')"
