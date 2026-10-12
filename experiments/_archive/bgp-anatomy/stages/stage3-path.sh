#!/bin/bash
# 3단계 — 경로: 여권에 도장이 쌓이는 과정. AS_PATH, NEXT_HOP 변화, Withdraw, 루프 방지.
set -u; cd "$(dirname "$0")/.."; . ./lib.sh
OUT=capture/stage3.txt; : > "$OUT"; exec > >(tee -a "$OUT") 2>&1

say "3-0 지금 203.0.113.0/24(AS500 발) 가 세계에 어떻게 퍼져 있나 — 도장 쌓임"
./world.sh $VICTIM
echo "   r400:500   r200/r300:400 500   r100:200 400 500 / r666:300 400 500"
echo "   AS 하나 지날 때마다 AS_PATH 앞에 도장이 하나씩 붙는다."

say "3-A eBGP 를 넘을 때 NEXT_HOP 이 바뀐다 — r400→r300 구간에서 UPDATE 를 잡는다"
cap_start s3-update r400 eth2 "tcp port 179"   # r400 eth2 ─ r300 eth2
# 재광고를 확실히 유발: r500 이 프리픽스를 내렸다가 다시 올린다 → withdraw + update 가 r400→r300 으로 흐른다
cfg r500 "router bgp 500" "address-family ipv4 unicast" "no network 203.0.113.0/24"; sleep 2
cfg r500 "router bgp 500" "address-family ipv4 unicast" "network 203.0.113.0/24"; sleep 3
cap_stop
echo "→ capture/s3-update.pcap : UPDATE 의 NEXT_HOP 이 광고하는 라우터(10.3.4.2=r400) 로 바뀐다, AS_PATH=400 500"
vt r300 "show bgp ipv4 unicast $VICTIM json" | python3 -c '
import json,sys;p=json.load(sys.stdin)["paths"][0]
print("   r300 이 받은 값: next-hop",p["nexthops"][0]["ip"]," as-path",p["aspath"]["string"])'

say "3-B Withdraw — AS500 이 광고를 내리면 \"저 이제 그 주소 안 살아요\""
cap_start s3-withdraw r400 eth2 "tcp port 179"
cfg r500 "router bgp 500" "address-family ipv4 unicast" "no network 203.0.113.0/24"
sleep 3; cap_stop
echo "$(ts) r100 에서 203.0.113.0/24 조회:"
vt r100 "show bgp ipv4 unicast $VICTIM json" | python3 -c '
import json,sys;d=json.load(sys.stdin);print("   경로 수:",len(d.get("paths",[])),"(0 이면 세계에서 사라짐)")'
echo "→ capture/s3-withdraw.pcap : UPDATE 의 Withdrawn Routes 필드에 203.0.113.0/24"
cfg r500 "router bgp 500" "address-family ipv4 unicast" "network 203.0.113.0/24"; sleep 3

say "3-C 루프 방지 — 자기 도장이 찍힌 여권은 입국 거부. allowas-in 으로 일부러 뚫으면?"
echo "r100 은 자기 프리픽스 198.51.100.0/24 를 r200·r300 에게 광고."
echo "그게 r400 거쳐 되돌아와도 AS_PATH 에 100 이 있으면 r100 은 거부한다(기본 동작)."
vt r100 "show bgp ipv4 unicast 198.51.100.0/24 json" | python3 -c '
import json,sys;d=json.load(sys.stdin)
ext=[p for p in d.get("paths",[]) if not p.get("local")]
print("   r100 이 외부에서 받은 198.51.100.0/24 경로 수:",len(ext),"(0 = 루프 차단 정상)")'
echo "   → allowas-in 을 켜면 받기 시작하지만 best 는 여전히 자기 local(가중치 32768)."
say "3단계 끝"
