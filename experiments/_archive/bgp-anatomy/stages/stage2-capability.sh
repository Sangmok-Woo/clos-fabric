#!/bin/bash
# 2단계 — 약속: 수교 조약(Capabilities)과 안부 인사(KEEPALIVE/Hold timer).
# 비유: "우리 이런 거 할 줄 알아요" 목록 교환 + "N초마다 안부, M초 침묵이면 끝".
set -u; cd "$(dirname "$0")/.."; . ./lib.sh
OUT=capture/stage2.txt; : > "$OUT"; exec > >(tee -a "$OUT") 2>&1
L=r100 RIP=10.1.2.2

say "2-0 OPEN 안의 Capabilities 를 캡처해서 열어 본다"
cap_start s2-open $L eth1 "tcp port 179"
vt $L "clear bgp 10.1.2.2"; sleep 4; cap_stop
echo "→ capture/s2-open.pcap : OPEN 패킷 Optional Parameters 에 Capability 목록"
echo "   (Wireshark 에서: Multiprotocol IPv4-unicast, 4-byte AS, Route Refresh, Graceful Restart 등)"
echo "$(ts) r100 이 본 이웃의 능력:"
vt $L "show bgp neighbor 10.1.2.2" | grep -iA12 'Neighbor capabilities' | sed 's/^/   /'

say "2-A Hold time 협상 — 양쪽이 다르면 작은 쪽으로 합의된다"
echo "r100 은 10/30(기본), r200 쪽에서 보는 협상 결과:"
cfg r200 "router bgp 200" "neighbor 10.1.2.1 timers 5 15"   # r200→r100 은 5/15 제안
vt r200 "clear bgp 10.1.2.1"; for i in $(seq 1 20); do vt r200 "show bgp neighbor 10.1.2.1 json" 2>/dev/null | grep -q Established && break; sleep 1; done
vt r200 "show bgp neighbor 10.1.2.1 json" | python3 -c '
import json,sys;d=json.load(sys.stdin)["10.1.2.1"]
print("   내 제안 holdtime=15, 상대=30 → 합의 holdtime =",d.get("bgpTimerHoldTimeMsecs",0)//1000,"초 (작은 쪽)")'
cfg r200 "router bgp 200" "no neighbor 10.1.2.1 timers 5 15"; vt r200 "clear bgp 10.1.2.1"; for i in $(seq 1 20); do vt r200 "show bgp neighbor 10.1.2.1 json" 2>/dev/null | grep -q Established && break; sleep 1; done

say "2-B 약속을 어기면 결별 — KEEPALIVE 를 끊어 Hold timer 를 만료시킨다"
# 기본 타이머(keepalive 10 / hold 30). 이미 선 세션에서 clear 없이 r200→r100 KEEPALIVE 만 끊는다.
nstate(){ vt $L "show bgp neighbor 10.1.2.2 json" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["10.1.2.2"]["bgpState"])
except: print("?")'; }
printf 'Established 대기: '; for i in $(seq 1 30); do [ "$(nstate)" = Established ] && { echo "ok"; break; }; sleep 1; done
cap_start s2-holdexp $L eth1 "tcp port 179"
t0=$(date +%s)
echo "$(ts) r200→r100 KEEPALIVE(179) egress DROP — 30초 hold 가 만료되면 끊긴다"
# BGP 연결을 누가 걸었는지에 따라 r200 의 179 가 sport 일 수도 dport 일 수도 있어 둘 다 막는다
nsx r200 iptables -A OUTPUT -p tcp --sport 179 -d 10.1.2.1 -j DROP
nsx r200 iptables -A OUTPUT -p tcp --dport 179 -d 10.1.2.1 -j DROP
for i in $(seq 1 40); do s=$(nstate); [ "$s" != Established ] && { echo "   $(( $(date +%s)-t0 ))초 만에 $s 로 떨어짐 (Hold Timer Expired)"; break; }; sleep 1; done
cap_stop
echo "→ capture/s2-holdexp.pcap 의 NOTIFICATION:"
nsx $L tcpdump -v -nn -r capture/s2-holdexp.pcap 2>/dev/null | grep -iE 'notif' | head -1 | sed 's/^/   /'
nsx r200 iptables -F; vt $L "clear bgp 10.1.2.2" >/dev/null; wait_up 40 >/dev/null
echo "   연결 고리: EVPN 이 BGP 위에 올라타는 것도 이 Multiprotocol 능력 협상(2-0) 덕분."
say "2단계 끝 — 세션 원복"
