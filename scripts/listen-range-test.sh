#!/usr/bin/env bash
# 스파인의 "이웃 목록"을 지우고, 대역만 열어두는 방식(동적 이웃)으로 바꿔본다.
#   기존:  neighbor 10.1.1.1 peer-group FABRIC   ... 리프 수만큼 늘어남
#   변경:  bgp listen range 10.1.1.0/24 peer-group FABRIC   ... 한 줄로 끝
# 확인이 끝나면 원래대로 되돌린다.
# (configs/*.conf 는 읽기 전용 마운트라, 이 스크립트는 실행 중인 설정만 건드린다)
set -u
SPINE=${SPINE:-spine1}
AS=${AS:-65001}
RANGE=${RANGE:-10.1.1.0/24}
LEAVES="10.1.1.1 10.1.1.3 10.1.1.5 10.1.1.7"
LEAFNODES="leaf1 leaf2 leaf3 leaf4"
v() { docker exec clab-clos-$SPINE vtysh "$@" 2>/dev/null; }

echo "=== 0) 지금 상태 ==="
echo "  $SPINE 설정의 이웃 줄 개수 : $(v -c 'show running-config' | grep -c 'neighbor 10\.')"
echo "  붙어 있는 세션            : $(v -c 'show ip bgp summary json' | grep -o '"state":"Established"' | wc -l) / 4"

echo
echo "=== 1) 대역을 열고(listen range), 이웃 목록은 전부 삭제 ==="
CMD=(-c "conf t" -c "router bgp $AS" -c "bgp listen range $RANGE peer-group FABRIC" -c "bgp listen limit 128")
for ip in $LEAVES; do CMD+=(-c "no neighbor $ip"); done
v "${CMD[@]}" >/dev/null
echo "  $SPINE 설정의 이웃 줄 개수 : $(v -c 'show running-config' | grep -c 'neighbor 10\.')  ← 0 이어야 한다"
v -c "show running-config" | grep -E "listen (range|limit)" | sed 's/^/  /'

echo
echo "=== 2) 리프가 스스로 다시 붙기를 기다린다 ==="
echo "  (실제 환경에서는 리프의 재접속 타이머를 기다리면 된다. 여기서는 clear 로 즉시 시도시킨다)"
for n in $LEAFNODES; do docker exec clab-clos-$n vtysh -c "clear bgp *" >/dev/null 2>&1; done
for i in $(seq 1 12); do
  c=$(v -c 'show ip bgp summary json' | grep -o '"state":"Established"' | wc -l)
  echo "  ${i}0초... established $c / 4"
  [ "$c" = "4" ] && break
  sleep 10
done

echo
echo "=== 3) 결과 ==="
v -c "show ip bgp summary" | grep -E "Neighbor|10\.1\.1\.|Dynamic|Total"
echo
echo "-- 서버 통신 (h1 -> h4) --"
docker exec clab-clos-h1 ping -c 2 -W 2 172.16.14.10 | tail -2
echo
echo "-- leaf1 이 보는 경로 (넥스트홉 2개면 스파인 둘 다 정상) --"
docker exec clab-clos-leaf1 ip route show 172.16.14.0/24 | sed 's/^/  /'

echo
echo "=== 4) 원래 설정으로 되돌리기 ==="
CMD=(-c "conf t" -c "router bgp $AS" -c "no bgp listen range $RANGE peer-group FABRIC" -c "no bgp listen limit")
i=1
for ip in $LEAVES; do
  CMD+=(-c "neighbor $ip peer-group FABRIC" -c "neighbor $ip description leaf$i")
  i=$((i+1))
done
v "${CMD[@]}" >/dev/null
for n in $LEAFNODES; do docker exec clab-clos-$n vtysh -c "clear bgp *" >/dev/null 2>&1; done
sleep 15
echo "  이웃 줄 개수 : $(v -c 'show running-config' | grep -c 'neighbor 10\.')  ← 8 이어야 한다 (이웃 4 × 2줄)"
echo "  listen 설정  : $(v -c 'show running-config' | grep -c 'bgp listen')  ← 0 이어야 한다"
echo "  세션         : $(v -c 'show ip bgp summary json' | grep -o '"state":"Established"' | wc -l) / 4"
