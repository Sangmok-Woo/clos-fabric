#!/usr/bin/env bash
# 실험 20 — EVPN MAC 이동과 중복 MAC 감지
#   VM 하나(MAC 02:21:00:00:00:01, 10.10.10.121)가 leaf1 → leaf2 로 옮겨 간다. VM 의 두 자리를
#   netns 두 개(vmA: leaf1:eth7, vmB: leaf2:eth7)로 미리 만들어 두고, 한쪽 링크를 내리고 다른 쪽을 올리는 것이 '이사'다.
#   g3(leaf3 뒤)가 10ms 마다 VM 에 ping 해서 끊긴 시간을 잰다. leaf3 의 EVPN 주소록(원격 VTEP, MAC Mobility 순번)을 같이 본다.
#
#   A 기준: vmA(leaf1)에 있음
#   B 이사 + GARP:  leaf1 → leaf2, 도착하자마자 GARP 3개
#   C 조용한 이사:   leaf2 → leaf1, GARP 없음 (누가 먼저 말을 걸 때까지 VM 은 가만히 있다)
#   C2 진짜 조용한 이사: C 에서 VM 이 IPv6 DAD/MLD 로 사실상 말을 해 버려서, IPv6 를 끄고 다시 (leaf1 → leaf2)
#   D 중복 MAC:      vmA·vmB 둘 다 켜고 각자 0.5초마다 GARP (MAC 을 복제한 VM 두 대) 60초 — FRR 기본 감지(180초에 5번)
#   F 중복 + freeze: dup-addr-detection freeze 30 을 켜고 D 를 다시
# 먼저: experiments/_wip/16-roce-vxlan-ecn/run2/scripts/setup.sh (VNI 10010 을 leaf2 에도, g3 = vr3)
# 사용: run.sh [A B C D F]
set -u
. "$(dirname "$0")/../16-roce-vxlan-ecn/run2/scripts/common.sh"
H=$(cd "$(dirname "$0")" && pwd)
OUT=$H/capture; mkdir -p "$OUT" "$H/state"
STEPS=${*:-A B C C2 D F}
[ $# -eq 0 ] && rm -rf "$OUT"/*
exec > >(tee -a "$OUT/run-output.txt") 2>&1
MAC=02:21:00:00:00:01; VIP=10.10.10.121

ev() { dx $1 vtysh -c "$2"; }
# leaf3 이 아는 VM: "VTEP=… seq=…" (FRR json)
where3() { dx leaf3 vtysh -c "show evpn mac vni $VNI mac $MAC json" 2>/dev/null | MAC=$MAC python3 "$H/macjson.py"; }
macline() { ev $1 "show evpn mac vni $VNI mac $MAC" 2>/dev/null | grep -E 'MAC:|Remote VTEP|Intf|Local Seq|Duplicate|Sync|dup' | tr -s ' \n' ' '; }
updates() { ev spine1 "show bgp l2vpn evpn summary json" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin); p=d.get("peers",{})
print(sum(v.get("msgRcvd",0) for v in p.values()))'; }

vm_prep() {
  for s in A:1 B:2; do
    local v=${s%%:*} n=${s##*:}
    ip netns list | grep -qw vm$v || ip netns add vm$v
    if ! ip netns exec vm$v ip link show m$v >/dev/null 2>&1; then
      ip link add m$v type veth peer name eth7 netns "$(pid leaf$n)"
      ip link set m$v netns vm$v
      ip netns exec vm$v ip link set m$v address $MAC mtu 1500
      ip netns exec vm$v ip addr add $VIP/24 dev m$v
      ip netns exec vm$v ip link set lo up
      dx leaf$n ip link set eth7 mtu 9000 master br$VNI up
    fi
  done
}
up()   { ip netns exec vm$1 ip link set m$1 up; }
down() { ip netns exec vm$1 ip link set m$1 down; }
garp() { ip netns exec vm$1 python3 "$H/garp.py" m$1 $VIP ${2:-3} ${3:-0.05}; }
probe_start() { ping -I vr3 -i 0.01 -D -O -W 1 $VIP > "$OUT/$1-ping.txt" 2>&1 & PP=$!; }
probe_stop()  { kill -INT $PP 2>/dev/null; wait $PP 2>/dev/null; python3 "$H/gap.py" "$OUT/$1-ping.txt" 10; }

A() {
  say "A  기준 — VM 은 leaf1(vmA)"
  down B; up A; garp A 1
  sleep 3
  probe_start A; sleep 5; echo "  ping: $(probe_stop A)"
  echo "  leaf3 이 아는 VM: $(where3)"
  echo "  leaf1: $(macline leaf1)"
}

B() {
  say "B  이사 leaf1 → leaf2 + GARP"
  down B; up A; garp A 1; sleep 3
  local u0; u0=$(updates)
  probe_start B; sleep 3
  local t0; t0=$(date +%s.%N)
  down A; up B; garp B 3 0.05
  echo "  이사 시각 T0 = $t0"
  for i in $(seq 40); do sleep 0.05; w=$(where3); echo "$w" | grep -q 10.255.1.2 && { echo "  leaf3 주소록이 leaf2 를 가리킨 시각: T0 + $(echo "$(date +%s.%N) - $t0" | awk '{printf "%.2f", $1 - $3}')s"; break; }; done 2>/dev/null
  sleep 4; echo "  ping: $(probe_stop B)"
  echo "  leaf3 이 아는 VM: $(where3)"
  echo "  leaf2: $(macline leaf2)"
  echo "  스파인1 이 받은 EVPN 메시지 +$(( $(updates) - u0 ))"
}

C() {
  say "C  조용한 이사 leaf2 → leaf1 (GARP 없음)"
  down A; up B; garp B 1; sleep 3
  probe_start C; sleep 3
  local t0; t0=$(date +%s.%N)
  down B; up A
  echo "  이사 시각 T0 = $t0  (VM 은 아무것도 보내지 않는다)"
  local hit=""
  for i in $(seq 200); do sleep 0.05; w=$(where3); echo "$w" | grep -q 10.255.1.1 && { hit=$(awk -v a=$(date +%s.%N) -v b=$t0 'BEGIN{printf "%.2f", a-b}'); break; }; done
  echo "  leaf3 주소록이 leaf1 을 가리킨 시각: T0 + ${hit:-10초 안에 안 바뀜}s"
  sleep 4; echo "  ping: $(probe_stop C)"
  echo "  leaf3 이 아는 VM: $(where3)"
  echo "  leaf1: $(macline leaf1)"
}

C2() {
  say "C2 진짜 조용한 이사 leaf1 → leaf2 — VM 의 IPv6 를 꺼서 링크가 올라와도 아무것도 안 보내게"
  for v in A B; do ip netns exec vm$v sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 net.ipv6.conf.m$v.disable_ipv6=1; done
  down B; up A; garp A 1; sleep 3
  nsenter -t "$(pid leaf2)" -n tcpdump -i eth7 -s 128 -U -nn -w "$OUT/C2-leaf2-eth7.pcap" >/dev/null 2>&1 & local cp=$!
  probe_start C2; sleep 3
  local t0; t0=$(date +%s.%N)
  down A; up B
  echo "  이사 시각 T0 = $t0  (GARP 없음, IPv6 꺼짐)"
  local hit=""
  for i in $(seq 300); do sleep 0.05; w=$(where3); echo "$w" | grep -q 10.255.1.2 && { hit=$(awk -v a=$(date +%s.%N) -v b=$t0 'BEGIN{printf "%.2f", a-b}'); break; }; done
  echo "  leaf3 주소록이 leaf2 를 가리킨 시각: T0 + ${hit:-15초 안에 안 바뀜}s"
  sleep 4; echo "  ping: $(probe_stop C2)"
  kill $cp 2>/dev/null; sleep 0.3
  echo "  leaf2:eth7 (VM 쪽) 첫 패킷들:"; tcpdump -nn -e -r "$OUT/C2-leaf2-eth7.pcap" 2>/dev/null | head -6 | cut -c1-150 | sed 's/^/     /'
  for v in A B; do ip netns exec vm$v sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.m$v.disable_ipv6=0; done
}

dup_run() {   # dup_run <id> <제목>
  say "$1  $2"
  up A; up B
  local u0; u0=$(updates)
  probe_start $1
  local t0; t0=$(date +%s)
  # 두 VM 이 0.5초마다 번갈아 GARP (0.25초 엇갈려서)
  ( for i in $(seq 120); do garp A 1; sleep 0.25; garp B 1; sleep 0.25; done ) &
  local gp=$!
  local det=""
  for i in $(seq 70); do
    sleep 1
    local s1 s2; s1=$(macline leaf1); s2=$(macline leaf2)
    printf "  +%2ds  leaf3: %s\n" $(( $(date +%s) - t0 )) "$(where3)" >> "$OUT/$1-timeline.txt"
    if [ -z "$det" ] && { echo "$s1 $s2" | grep -qiE 'duplicate|dup'; } && ev leaf1 "show evpn mac vni $VNI duplicate" 2>/dev/null | grep -q -i "$MAC"; then det=$(( $(date +%s) - t0 )); fi
    [ -z "$det" ] && ev leaf2 "show evpn mac vni $VNI duplicate" 2>/dev/null | grep -q -i "$MAC" && det=$(( $(date +%s) - t0 ))
  done
  kill $gp 2>/dev/null; wait $gp 2>/dev/null
  if [ -n "$det" ]; then echo "  중복 감지: +${det}초"; else echo "  중복 감지: 60초 안에 감지 안 됨"; fi
  echo "  ping: $(probe_stop $1)"
  echo "  스파인1 이 받은 EVPN 메시지 +$(( $(updates) - u0 ))  (60초)"
  for n in leaf1 leaf2; do echo "  $n duplicate 목록:"; ev $n "show evpn mac vni $VNI duplicate" | sed 's/^/     /'; done
  echo "  leaf1: $(macline leaf1)"; echo "  leaf2: $(macline leaf2)"; echo "  leaf3 이 아는 VM: $(where3)"
  sed -n '1p;10p;20p;30p;45p;60p' "$OUT/$1-timeline.txt"
  down B
  for n in 1 2; do ev leaf$n "clear evpn dup-addr vni $VNI mac $MAC" >/dev/null 2>&1; done
}

D() { dup_run D "중복 MAC — vmA(leaf1)·vmB(leaf2) 동시에, FRR 기본 감지값"; }
F() {
  for n in 1 2 3 4; do ev leaf$n "show running-config" | grep -i dup-addr | sed "s/^/  leaf$n 이전: /"; done
  for n in 1 2; do dx leaf$n vtysh -c "conf t" -c "router bgp 6501$n" -c "address-family l2vpn evpn" -c "dup-addr-detection freeze 30" >/dev/null; done
  touch "$H/state/freeze"
  dup_run F "중복 MAC + dup-addr-detection freeze 30"
  for n in 1 2; do dx leaf$n vtysh -c "conf t" -c "router bgp 6501$n" -c "address-family l2vpn evpn" -c "no dup-addr-detection freeze 30" >/dev/null; done
  rm -f "$H/state/freeze"
}

date
vm_prep
echo "FRR 중복 감지 기본값 (leaf1 show evpn):"; ev leaf1 "show evpn" | sed 's/^/  /'
for s in $STEPS; do $s; done
"$H/restore.sh"
date
