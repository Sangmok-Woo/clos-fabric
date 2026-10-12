#!/bin/bash
# 6단계 — 방어: 위조 소문 걸러내기. 기초 필터 + RPKI ROV(StayRTR).
set -u; cd "$(dirname "$0")/.."; . ./lib.sh
OUT=capture/stage6.txt; : > "$OUT"; exec > >(tee -a "$OUT") 2>&1
V=203.0.113.0/24

say "6-A 기초 방어 — 고객(AS666) 세션에 prefix-list (받을 프리픽스를 못 박는다)"
echo "r300 은 고객 AS666 에게서 100.66.6.0/24 만 받아야 한다. 그 밖은 입구에서 버린다."
cfg r300 "ip prefix-list CUST666 seq 5 permit 100.66.6.0/24" \
         "route-map FROM666 permit 10" "match ip address prefix-list CUST666" "exit" \
         "router bgp 300" "address-family ipv4 unicast" "neighbor 10.3.6.2 route-map FROM666 in"
vt r300 "clear bgp 10.3.6.2 in"; sleep 2
echo "이 상태에서 AS666 이 $V 하이재킹을 시도하면:"
hijack_add r666 10.3.6.1 $V
vt r300 "show bgp ipv4 unicast $V json" | python3 -c '
import json,sys;ps=json.load(sys.stdin).get("paths",[])
n=sum(1 for p in ps if p["aspath"]["string"].startswith("666"))
print("   r300 이 666 경유로 받은 $V 경로:",n,"(0 = prefix-list 가 입구에서 차단)".replace("$V",""))'
hijack_del r666 10.3.6.1 $V
cfg r300 "router bgp 300" "address-family ipv4 unicast" "no neighbor 10.3.6.2 route-map FROM666 in" \
         "exit" "neighbor 10.3.6.2 route-map CUST-IN in"
cfg r300 "no route-map FROM666" "no ip prefix-list CUST666 seq 5 permit 100.66.6.0/24"
vt r300 "clear bgp 10.3.6.2 in"; sleep 2
echo "   → 5-a·5-c 류 하이재킹은 고객 입구 필터에서 이미 막힌다. 운영의 1차 방어선."

say "6-B RPKI ROV — StayRTR 캐시(172.20.20.240:8282)로 Origin 검증, Invalid 는 버린다"
echo "ROA(rpki/roas.json): $V 주인은 AS500/maxLen24, 100.66.6.0/24 는 AS666 ..."
for r in $ROUTERS; do
  cfg $r "router bgp ${r#r}" "rpki" "rpki cache tcp 172.20.20.240 8282 preference 1" >/dev/null
done
# r300 의 고객 666 입구에 ROV: invalid 는 deny, 나머지는 통과(고객이라 LP200)
cfg r300 "route-map ROV deny 10" "match rpki invalid" "exit" \
         "route-map ROV permit 20" "set local-preference 200" "set community 300:1 additive" "exit" \
         "router bgp 300" "address-family ipv4 unicast" "neighbor 10.3.6.2 route-map ROV in"
vt r300 "clear bgp 10.3.6.2 in"
printf "RPKI 캐시 연결 대기: "; for i in $(seq 1 25); do vt r300 "show rpki cache-connection" 2>/dev/null | grep -q "(connected)" && { echo "${i}초"; break; }; sleep 1; done
echo "$(ts) RPKI 캐시:"; vt r300 "show rpki cache-connection" 2>/dev/null | grep -iE "connected|pref" | sed "s/^/   /"
echo "ROA 개수:"; printf '   ROA %s개\n' "$(vt r300 'show rpki prefix-table' 2>/dev/null | grep -cE '[0-9]+ *-')"; sleep 3

echo; echo "[5-a] 666 이 $V 를 자기 출처로 하이재킹 → Invalid (버려짐)"
hijack_add r666 10.3.6.1 $V
vt r300 "show bgp ipv4 unicast $V json" | python3 -c '
import json,sys;ps=json.load(sys.stdin).get("paths",[])
h=[p for p in ps if p["aspath"]["string"].startswith("666")]
print("   666 경로:", (h[0].get("rpkiValidationState") if h else "(입구에서 deny → 후보 없음)"))
print("   r300 best:", [p["aspath"]["string"] for p in ps if p.get("bestpath",{}).get("overall")])'
hijack_del r666 10.3.6.1 $V

echo; echo "[5-b] 666 이 /25 를 광고 → maxLength 24 위반으로 Invalid (버려짐)"
hijack_add r666 10.3.6.1 203.0.113.0/25
vt r300 "show bgp ipv4 unicast 203.0.113.0/25 json" | python3 -c '
import json,sys;ps=json.load(sys.stdin).get("paths",[])
print("   /25:", (ps[0].get("rpkiValidationState") if ps else "(deny → 후보 없음)"),"— maxLength 위반")'
hijack_del r666 10.3.6.1 203.0.113.0/25

echo; echo "[5-d] 666 이 666 500 으로 출처 위조 → 출처가 500 이라 Valid 로 통과(!)"
cfg r666 "route-map FORGE permit 10" "set as-path prepend 500"
cfg r666 "router bgp 666" "address-family ipv4 unicast" "neighbor 10.3.6.1 route-map FORGE out"
hijack_add r666 10.3.6.1 $V
vt r300 "show bgp ipv4 unicast $V json" | python3 -c '
import json,sys;ps=json.load(sys.stdin).get("paths",[])
h=[p for p in ps if "666" in p["aspath"]["string"]]
print("   666 500 경로:", (h[0].get("rpkiValidationState") if h else "-"),"← 출처만 보니 500 이면 통과. RPKI 의 구멍.")'
hijack_del r666 10.3.6.1 $V
cfg r666 "router bgp 666" "address-family ipv4 unicast" "no neighbor 10.3.6.1 route-map FORGE out"
cfg r666 "no route-map FORGE"; vt r666 "clear bgp 10.3.6.1 soft out"; sleep 2

say "원복 — ROV 강제 해제 (rpki 캐시 연결은 남겨 둔다)"
# ROV 입구 정책만 풀고 고객 기본정책(CUST-IN)으로 되돌린다.
cfg r300 "router bgp 300" "address-family ipv4 unicast" "no neighbor 10.3.6.2 route-map ROV in" \
         "exit" "neighbor 10.3.6.2 route-map CUST-IN in"
cfg r300 "no route-map ROV"
vt r300 "clear bgp 10.3.6.2 in"; sleep 3
# 주의: 이 FRR 빌드는 `no rpki` 로 rpki 를 끄면 bgpd 가 죽는 일이 있다. 캐시 연결은 무해하므로
# (경로는 그대로, show 에 검증 상태만 뜬다) 남겨 둔다. 완전 초기화가 필요하면 ./up.sh 로 재배포.
echo "마지막 교훈: RPKI 는 여권의 '마지막 도장(출처 AS)'만 본다. 중간 경로(5-d)는 못 막는다."
echo "그 구멍을 메우려는 게 ASPA·BGPsec — 개념으로만."
say "6단계 끝"; ./world.sh $V
