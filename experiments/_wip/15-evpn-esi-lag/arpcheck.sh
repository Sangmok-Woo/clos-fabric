#!/usr/bin/env bash
# C 추가 확인: leaf1 업링크가 죽은 동안 hrem 의 ARP(이웃) 상태와 hmh 쪽 ARP 응답이 어느 줄로 나가는지.
#   흐름 4개를 55초 흘리고 T0+3 에 업링크 down, 45초 유지 (이웃 항목이 STALE 로 넘어가는 30초 남짓을 넘기려고). hrem 의 이웃 상태를 0.2초마다 기록.
set -u
. "$(dirname "$0")/common.sh"
D=$HERE/capture/C-arp; rm -rf "$D"; mkdir -p "$D"; CAPDIR=$D
SNAP=96 cap_start hmh-eth1 hmh eth1 arp
SNAP=96 cap_start hmh-eth2 hmh eth2 arp
SNAP=96 cap_start hrem-eth1 hrem eth1 arp
cap_wait 1
nsenter -t "$(pid hmh)" -n python3 "$HERE/probe.py" recv 7001 "$D/to_mh.rx" 58 & P1=$!
sleep 0.3
nsenter -t "$(pid hrem)" -n python3 "$HERE/probe.py" send $MHIP 7001 4 55 40000 "$D/to_mh.tx" & P2=$!
sleep 3; T0=$(date +%s.%N)
printf 'link set %s down\n' eth1 eth2 | nsx leaf1 ip -batch -
end=$(( $(date +%s) + 45 )); last=""
while [ "$(date +%s)" -lt $end ]; do
  s=$(nsx hrem ip neigh show $MHIP | awk '{print $NF}')
  [ "$s" != "$last" ] && { echo "T0+$(echo "$(date +%s.%N) $T0" | awk '{printf "%.1f",$1-$2}')  hrem 이웃 $MHIP: $s"; last=$s; }
  sleep 0.2
done
T1=$(date +%s.%N); printf 'link set %s up\n' eth1 eth2 | nsx leaf1 ip -batch -
echo "$T0 $T1" > "$D/times"; wait $P1 $P2
cap_stop
echo "--- ARP (T0 기준 초)"
for f in hrem-eth1 hmh-eth1 hmh-eth2; do
  tcpdump -tt -nn -r "$D/$f.pcap" 2>/dev/null | awk -v t0=$T0 -v f=$f '{t=$1-t0; $1=""; if (t>-1) printf "  %-10s %+6.2f %s\n", f, t, $0}'
done | sort -k2 -g | grep -vE "Request who-has 10.10.20.30 tell 10.10.20.10" | head -80
python3 - "$D" <<'PY'
import sys
from collections import defaultdict
d=sys.argv[1]; T0,T1=map(float,open(f"{d}/times").read().split())
t0,c,n=open(f"{d}/to_mh.tx").read().split(); t0=float(t0)
g=defaultdict(set)
for l in open(f"{d}/to_mh.rx"):
    i,s,_=l.split(); g[int(i)].add(int(s))
for i in range(int(n)):
    m=[t0+s*0.01-T0 for s in range(int(c)) if s not in g[i]]
    r=[];st=pv=None
    for x in m:
        if st is None: st=x
        elif x-pv>0.015: r.append((st,pv)); st=x
        pv=x
    if st is not None: r.append((st,pv))
    print(f"  흐름 {i} 원격→hmh 손실 구간(T0 기준):", ", ".join(f"{a:+.2f}~{b:+.2f}" for a,b in r) or "없음")
PY
rm -f "$D"/*.rx
