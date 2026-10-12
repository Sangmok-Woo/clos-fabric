#!/bin/bash
# 4단계 — 정책: 외교관의 판단. 나가는 길은 내가(Local Pref), 들어오는 길은 부탁만(prepend).
set -u; cd "$(dirname "$0")/.."; . ./lib.sh
OUT=capture/stage4.txt; : > "$OUT"; exec > >(tee -a "$OUT") 2>&1
P100=198.51.100.0/24

say "4-0 듀얼홈 AS100 의 나가는 길 — 지금은 어느 프로바이더로 나가나"
echo "r100 이 203.0.113.0/24 로 나가는 경로:"
vt r100 "show bgp ipv4 unicast $VICTIM json" | python3 -c '
import json,sys;p=[x for x in json.load(sys.stdin)["paths"] if x.get("bestpath",{}).get("overall")][0]
print("   via",p["nexthops"][0]["ip"],"as-path",p["aspath"]["string"],"(동률이면 라우터ID 가 가른다)")'

say "4-A 나가는 길 바꾸기 — r300 쪽에서 받는 경로의 Local Pref 를 올린다"
echo "r100 에서 r300(10.1.3.2) 으로 들어오는 모든 경로 LP 를 300 으로."
cfg r100 "route-map VIA-R300 permit 10" "set local-preference 300" "exit" \
         "router bgp 100" "address-family ipv4 unicast" \
         "neighbor 10.1.3.2 route-map VIA-R300 in"
vt r100 "clear bgp 10.1.3.2 soft in"; sleep 2
vt r100 "show bgp ipv4 unicast $VICTIM json" | python3 -c '
import json,sys;p=[x for x in json.load(sys.stdin)["paths"] if x.get("bestpath",{}).get("overall")][0]
print("   이제 via",p["nexthops"][0]["ip"],"LP",p.get("locPrf"),"→ 내 트래픽만 r300 쪽으로 바뀜")'
echo "   (남의 테이블은 그대로다. 나가는 길은 내가 혼자 정하는 것)"
# 원복
cfg r100 "router bgp 100" "address-family ipv4 unicast" "no neighbor 10.1.3.2 route-map VIA-R300 in"
cfg r100 "no route-map VIA-R300"; vt r100 "clear bgp 10.1.3.2 soft in"; sleep 2

say "4-B 들어오는 길 — AS_PATH prepend 로 r300 쪽 경로를 일부러 길게 만든다"
echo "prepend 전, 남들이 보는 198.51.100.0/24 출처 경로:"
./world.sh $P100
cfg r100 "route-map LONG-VIA-R300 permit 10" "set as-path prepend 100 100 100" "exit" \
         "router bgp 100" "address-family ipv4 unicast" \
         "neighbor 10.1.3.2 route-map LONG-VIA-R300 out"
vt r100 "clear bgp 10.1.3.2 soft out"; sleep 3
echo "prepend 후 (100 100 100 100 처럼 r300 경로가 길어져 남들이 r200 쪽을 고름):"
./world.sh $P100
cfg r100 "router bgp 100" "address-family ipv4 unicast" "no neighbor 10.1.3.2 route-map LONG-VIA-R300 out"
cfg r100 "no route-map LONG-VIA-R300"; vt r100 "clear bgp 10.1.3.2 soft out"; sleep 3

say "4-C community no-export — 경로가 어디까지 퍼지고 어디서 멈추나"
cfg r100 "route-map NOEXP permit 10" "set community no-export additive" "exit" \
# r100→r200 광고에 no-export → r200 은 받지만 r400 으로 안 넘김
cfg r100 "router bgp 100" "address-family ipv4 unicast" "neighbor 10.1.2.2 route-map NOEXP out"
vt r100 "clear bgp 10.1.2.2 soft out"; sleep 3
echo "r200 은 받나 / r400 은 r200 경유로는 못 받나(no-export 라 r200 이 더 안 퍼뜨림):"
for r in r200 r400; do printf "   %s: " $r; vt $r "show bgp ipv4 unicast $P100 json" | python3 -c '
import json,sys;ps=json.load(sys.stdin).get("paths",[])
paths=[p.get("aspath",{}).get("string","") for p in ps]
via200=[a for a in paths if a.split()[:1]==["200"]]
print(len(ps),"경로; as-path:",paths,"| 200 직수신:","있음" if via200 else "없음")'; done
cfg r100 "router bgp 100" "address-family ipv4 unicast" "no neighbor 10.1.2.2 route-map NOEXP out"
cfg r100 "no route-map NOEXP"; vt r100 "clear bgp 10.1.2.2 soft out"; sleep 2
say "4단계 끝"
