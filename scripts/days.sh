#!/usr/bin/env bash
# 하루 5분 시나리오 정의. day.sh 가 source 해서 쓴다.
# 각 날은 함수 5개: dNN_title / dNN_ask / dNN_inject / dNN_check / dNN_answer / dNN_restore
# 헬퍼(X, V, C, HR)는 day.sh 에 정의돼 있다.

TOTAL_DAYS=30

# ─────────────────────────────── 1주차: 물리와 링크 ───────────────────────────────

d01_title(){ echo "케이블 한 가닥 뽑기"; }
d01_ask(){ cat <<'EOF'
leaf1 에서 spine1 로 가는 케이블(eth1)을 방금 뽑았다.
leaf1 은 스파인이 2대인데 그중 1대와의 줄이 끊긴 상태다.

  Q1. h1 -> h4 핑은 될까, 안 될까?
  Q2. leaf1 의 172.16.14.0/24 경로에 넥스트홉이 몇 개 남을까?
EOF
}
d01_inject(){ X leaf1 ip link set eth1 down; }
d01_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp summary"
  docker exec clab-clos-h1 ping -c 3 172.16.14.10
EOF
}
d01_answer(){
  HR "leaf1 의 172.16.14.0/24 경로"; X leaf1 ip route show 172.16.14.0/24
  HR "h1 -> h4"; NS h1 ping -c 3 -W 1 172.16.14.10 | tail -3
  cat <<'EOF'

[해설]
넥스트홉이 2개 -> 1개로 줄었을 뿐, 통신은 그대로다.
Clos 패브릭의 존재 이유가 정확히 이거다. 리프는 모든 스파인에 다 붙어 있어서
스파인 N대 중 1대로 가는 길이 끊겨도 나머지 N-1개로 계속 나간다.
"이중화"가 문서상 문구가 아니라 라우팅 테이블의 nexthop 줄 수로 보인다는 걸 눈으로 확인한 것.
EOF
}
d01_restore(){ X leaf1 ip link set eth1 up; }

d02_title(){ echo "리프를 섬으로 만들기"; }
d02_ask(){ cat <<'EOF'
어제는 한 가닥이었는데, 오늘은 leaf1 의 두 가닥(eth1, eth2)을 다 뽑았다.
서버 h1 은 leaf1 에 그대로 붙어 있고 leaf1 도 멀쩡히 살아 있다.

  Q1. h1 -> h2 는 될까?
  Q2. h1 -> leaf1(172.16.11.1) 은 될까?  Q1과 답이 다를까?
EOF
}
d02_inject(){ X leaf1 ip link set eth1 down; X leaf1 ip link set eth2 down; }
d02_check(){ cat <<'EOF'
  docker exec clab-clos-h1 ping -c 2 172.16.11.1
  docker exec clab-clos-h1 ping -c 2 172.16.12.10
  docker exec clab-clos-leaf1 ip route | head
EOF
}
d02_answer(){
  HR "h1 -> 내 게이트웨이(leaf1)"; NS h1 ping -c 2 -W 1 172.16.11.1 | tail -2
  HR "h1 -> h2 (다른 랙)"; NS h1 ping -c 2 -W 1 172.16.12.10 | tail -2
  HR "leaf1 라우팅 테이블"; X leaf1 ip route
  cat <<'EOF'

[해설]
게이트웨이까지는 간다. 랙 밖으로는 못 나간다.
리프는 스파인이 없으면 아무 데도 못 가는 섬이 된다 — 리프끼리는 직접 연결이 없기 때문이다.
그래서 Clos 에서 스파인 대수는 곧 "리프가 살아남을 확률"이고,
반대로 리프의 업링크 수가 곧 그 랙 전체의 생명줄 개수다.
라우팅 테이블에서 172.16.12.0/24 같은 원격 경로가 통째로 사라진 것도 같이 보자.
EOF
}
d02_restore(){ X leaf1 ip link set eth1 up; X leaf1 ip link set eth2 up; }

d03_title(){ echo "스파인이 말없이 멎다 (hold timer)"; }
d03_ask(){ cat <<'EOF'
spine1 을 얼렸다(docker pause). 케이블은 그대로 꽂혀 있다 — 링크는 UP 이다.
장비가 죽은 게 아니라 "대답을 안 하는" 상태다.

  Q1. leaf1 은 spine1 이 죽은 걸 몇 초 만에 알아챌까? 왜 즉시가 아닐까?
  Q2. 그 몇 초 동안 spine1 을 타던 패킷들은 어디로 갈까?
EOF
}
d03_inject(){
  # docker pause 는 프로세스만 얼린다. 커널은 계속 패킷을 넘기므로
  # "장비가 먹통" 을 흉내내려면 포워딩도 같이 꺼야 한다.
  X spine1 sysctl -w net.ipv4.ip_forward=0 >/dev/null
  docker pause clab-clos-spine1 >/dev/null
  sleep 12
}
d03_check(){ cat <<'EOF'
  # 20초쯤 기다렸다가:
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp summary"
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp neighbors 10.1.1.0" | grep -i "Last reset"
  docker exec clab-clos-leaf1 sh -c "tail -10 /tmp/frr.log"
  docker exec clab-clos-leaf1 ip link show eth1 | head -1   # 링크는 UP 인 걸 확인
EOF
}
d03_answer(){
  HR "leaf1 eth1 링크 상태 (UP 인 게 핵심)"; X leaf1 ip link show eth1 | head -1
  HR "leaf1 BGP 세션"; V leaf1 "show ip bgp summary" | grep -E "Neighbor|10\.1\." 
  HR "세션이 왜 끊겼는지 (Last reset 사유)"; V leaf1 "show ip bgp neighbors 10.1.1.0" | grep -iE "BGP state|Last reset" | head -3
  HR "leaf1 FRR 로그"; FRRLOG leaf1 8 | grep -iE "hold|ADJCHANGE|NOTIFICATION" | tail -5
  cat <<'EOF'

[해설]
링크는 UP 인데 세션이 죽었다. 이게 "조용한 장애"다.
케이블을 뽑으면 커널이 즉시 알려주지만(0.2초), 상대가 얼기만 하면 알 방법이 없다.
그래서 BGP 는 hold timer 를 쓴다 — 이 랩은 timers 3 9 라 keepalive 3초, hold 9초.
9초 동안 아무 소식이 없어야 비로소 "죽었다"고 판정한다. 그 9초는 통째로 패킷이 버려지는 시간이다.
이 9초를 0.8초로 줄이는 게 BFD 고, 26일차에 직접 켜본다.
EOF
}
d03_restore(){
  docker unpause clab-clos-spine1 >/dev/null 2>&1 || true
  X spine1 sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

d04_title(){ echo "서버 포트 하나가 프리픽스를 지운다"; }
d04_ask(){ cat <<'EOF'
leaf3 의 서버쪽 포트(eth3, 172.16.13.1/24)를 내렸다. 패브릭 업링크는 멀쩡하다.

  Q1. leaf1 의 라우팅 테이블에서 172.16.13.0/24 는 살아 있을까 사라질까?
  Q2. 왜 그럴까? leaf3 의 frr.conf 에는 network 172.16.13.0/24 라고 적혀 있는데.
EOF
}
d04_inject(){ X leaf3 ip link set eth3 down; }
d04_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 ip route show 172.16.13.0/24
  docker exec clab-clos-leaf3 vtysh -c "show ip bgp neighbors 10.1.1.4 advertised-routes"
  docker exec clab-clos-h1 ping -c 2 172.16.13.10
EOF
}
d04_answer(){
  HR "leaf1 에서 본 172.16.13.0/24 (비어 있으면 사라진 것)"; X leaf1 ip route show 172.16.13.0/24; echo "(위가 비었으면 경로 없음)"
  HR "leaf3 가 spine1 에게 광고 중인 경로"; V leaf3 "show ip bgp neighbors 10.1.1.4 advertised-routes" | tail -8
  cat <<'EOF'

[해설]
사라진다. network 문은 "무조건 광고해라"가 아니라 "이 경로가 내 라우팅 테이블에 있으면 광고해라"다.
포트가 내려가면 커널의 connected 경로가 사라지고, 근거를 잃은 BGP 는 광고를 회수(withdraw)한다.
그래서 패브릭 전체가 "저 랙은 이제 없다"를 몇 초 만에 배운다.
이게 좋은 성질이다 — 죽은 랙으로 트래픽을 계속 보내지 않는다. 19~20일차에서 이 성질이 없는 static 경로와 비교한다.
EOF
}
d04_restore(){ X leaf3 ip link set eth3 up; }

d05_title(){ echo "작은 패킷은 되는데 큰 패킷만 죽는다 (MTU)"; }
d05_ask(){ cat <<'EOF'
leaf1 의 업링크 두 개(eth1, eth2)의 MTU 를 1500 -> 1400 으로 줄였다.
h1 의 랜카드는 그대로 1500 이다.

  Q1. 그냥 ping (56바이트) 은 될까?
  Q2. ping -s 1472 -M do (조각내지 말고 1500바이트로) 는 어떻게 될까?
EOF
}
d05_inject(){ X leaf1 ip link set eth1 mtu 1400; X leaf1 ip link set eth2 mtu 1400; }
d05_check(){ cat <<'EOF'
  docker exec clab-clos-h1 ping -c 2 172.16.14.10
  # alpine 의 busybox ping 에는 -M do 옵션이 없어서 호스트 ping 을 빌려 쓴다
  ./scripts/in.sh h1 ping -c 2 -s 1472 -M do 172.16.14.10
  docker exec clab-clos-leaf1 ip link show eth1 | head -1
EOF
}
d05_answer(){
  HR "작은 핑"; NS h1 ping -c 2 -W 1 172.16.14.10 | tail -2
  HR "큰 핑 (1472바이트, 조각내기 금지)"; NS h1 ping -c 2 -W 1 -s 1472 -M do 172.16.14.10 2>&1 | grep -vE "^$" | tail -5
  cat <<'EOF'

[해설]
작은 건 되고 큰 것만 죽는다. 현업에서 제일 사람 잡는 장애 유형이다.
핑도 되고 텔넷도 되는데 파일 전송만 멈추거나, HTTP 요청은 가는데 응답이 안 오거나.
이유: 1500바이트 패킷이 1400 짜리 문으로 못 들어가는데, DF(조각내지 마) 비트 때문에 자를 수도 없다.
그러면 라우터가 ICMP "Frag needed" 를 되돌려준다 — 위 출력에 그 메시지가 보일 것이다.
문제는 방화벽이 이 ICMP 를 막아버리면 아무 메시지도 없이 그냥 멈춘다는 것(= PMTU 블랙홀).
그래서 "핑은 되는데 안 돼요" 소리를 들으면 제일 먼저 큰 핑을 쏴본다.
EOF
}
d05_restore(){ X leaf1 ip link set eth1 mtu 1500; X leaf1 ip link set eth2 mtu 1500; }

d06_title(){ echo "ECMP 는 느린 길을 피하지 않는다"; }
d06_ask(){ cat <<'EOF'
leaf1 의 업링크 두 개(spine1 쪽 / spine2 쪽) 중 한 곳에만 100ms 지연을 걸었다.
어느 쪽인지는 안 알려준다. 링크도 BGP 도 전부 정상이고 경로도 2개 그대로다.

  Q1. h1 에서 h2, h3, h4 로 각각 핑을 쏘면 전부 느려질까? 일부만 느려질까?
  Q2. BGP 는 느린 쪽을 알아서 피해줄까?
EOF
}

# 172.16.14.10 흐름이 실제로 타는 업링크를 실측해서 고른다.
# (ECMP 해시라 어느 쪽을 탈지 미리 알 수 없어서, 카운터를 보고 정해야 한다)
d06_pick(){
  local b1 b2 a1 a2
  b1=$(X leaf1 cat /sys/class/net/eth1/statistics/tx_packets)
  b2=$(X leaf1 cat /sys/class/net/eth2/statistics/tx_packets)
  NS h1 ping -c 5 -i 0.2 -W 1 172.16.14.10 >/dev/null 2>&1
  a1=$(X leaf1 cat /sys/class/net/eth1/statistics/tx_packets)
  a2=$(X leaf1 cat /sys/class/net/eth2/statistics/tx_packets)
  if [ $((a1-b1)) -ge $((a2-b2)) ]; then echo eth1; else echo eth2; fi
}
d06_inject(){
  local i; i=$(d06_pick)
  echo "$i" > "$LAB_DIR/.day06-iface"
  X leaf1 tc qdisc replace dev "$i" root netem delay 100ms
}
d06_check(){ cat <<'EOF'
  docker exec clab-clos-h1 ping -c 4 172.16.12.10
  docker exec clab-clos-h1 ping -c 4 172.16.13.10
  docker exec clab-clos-h1 ping -c 4 172.16.14.10
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
  docker exec clab-clos-leaf1 tc qdisc show          # 어디에 걸었는지 여기 보인다
EOF
}
d06_answer(){
  local i tgt
  i=$(cat "$LAB_DIR/.day06-iface" 2>/dev/null || echo eth1)
  HR "목적지별 응답시간"
  for tgt in 172.16.12.10 172.16.13.10 172.16.14.10; do
    printf "  h1 -> %-15s : " "$tgt"
    NS h1 ping -c 4 -W 2 "$tgt" 2>/dev/null | tail -1 | awk -F'[/ ]' '{print $8" ms (평균)"}'
  done
  HR "지연을 건 곳"; echo "  leaf1 의 $i"; X leaf1 tc qdisc show dev "$i"
  HR "경로는 여전히 2개 (BGP 는 아무 불평이 없다)"; X leaf1 ip route show 172.16.14.0/24
  cat <<'EOF'

[해설]
전부 느려지는 게 아니라 일부만 느려진다. 그리고 경로는 여전히 2개고 BGP 는 아무 불평이 없다.

이유는 두 가지다.
1) 지연은 BGP 의 판단 기준이 아니다. BGP 는 AS-path 길이 같은 걸로 고르지, 빠른지 느린지는 안 본다.
2) ECMP 는 출발지/목적지를 해시해서 나온 숫자로 길을 고른다. 그 길의 상태는 안 본다.
   그래서 목적지마다 운이 갈린다 — 느린 링크로 배정된 목적지만 계속 느리다.

현업에서 "일부 서버만 느려요" 가 정확히 이 모양으로 들어온다.
평균 지표는 멀쩡하고(절반은 정상이니까), 재현도 잘 안 되고(다른 서버로 테스트하면 빠르다),
장비 알람도 안 울린다(링크는 UP 이고 세션도 Established 니까).

찾는 법은 27일차와 같다 — 느린 목적지들의 공통점을 찾는 것. 전부 같은 링크를 타고 있으면 그 링크가 범인이다.
고치려면 사람이 개입해야 한다. 그 링크를 빼거나(트래픽을 다른 쪽으로 몰거나) 물리 원인을 잡거나.
EOF
}
d06_restore(){
  X leaf1 tc qdisc del dev eth1 root 2>/dev/null || true
  X leaf1 tc qdisc del dev eth2 root 2>/dev/null || true
  rm -f "$LAB_DIR/.day06-iface"
}

# ─────────────────────────────── 2주차: BGP 설정 ───────────────────────────────

d07_title(){ echo "세션을 손으로 내려보기 (shutdown)"; }
d07_ask(){ cat <<'EOF'
leaf1 에서 spine1 과의 BGP 이웃을 shutdown 했다. 케이블도 링크도 멀쩡하다.

  Q1. 1일차(케이블 뽑기)와 결과가 같을까 다를까?
  Q2. show ip bgp summary 의 상태 칸에 뭐라고 찍힐까? Established? Idle? Active?
EOF
}
d07_inject(){ C leaf1 "router bgp 65011" "neighbor 10.1.1.0 shutdown"; }
d07_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp summary"
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
  docker exec clab-clos-leaf1 ip link show eth1 | head -1
EOF
}
d07_answer(){
  HR "leaf1 BGP 세션"; V leaf1 "show ip bgp summary" | grep -E "Neighbor|10\.1\."
  HR "링크는 UP"; X leaf1 ip link show eth1 | head -1
  HR "경로"; X leaf1 ip route show 172.16.14.0/24
  cat <<'EOF'

[해설]
결과(넥스트홉 1개)는 1일차와 똑같은데 원인 표시가 다르다.
상태 칸이 Idle (Admin) 으로 찍힌다 — "관리자가 껐다"는 뜻이다.
케이블 문제면 Active 나 Connect 로 찍힌다.
장애 대응할 때 이 구분이 시간을 아껴준다: Idle (Admin) 이면 물리 점검하러 갈 필요가 없다.
누군가 작업하다 안 되돌린 shutdown 이 남아 있는 경우가 실제로 흔하다.
EOF
}
d07_restore(){ C leaf1 "router bgp 65011" "no neighbor 10.1.1.0 shutdown"; }

d08_title(){ echo "편도만 끊어보기 (돌아올 길이 없다)"; }
d08_ask(){ cat <<'EOF'
leaf1 에서 network 172.16.11.0/24 광고를 지웠다.
h1 은 여전히 172.16.11.10 을 달고 있고, leaf1 도 h1 으로 가는 길을 안다.
지운 건 "다른 랙들에게 우리 랙 주소를 알려주는 것" 뿐이다.

  Q1. h1 -> h2 핑은 될까?
  Q2. 안 된다면, 패킷은 어디까지 갔다가 어디서 죽을까?
EOF
}
d08_inject(){ C leaf1 "router bgp 65011" "address-family ipv4 unicast" "no network 172.16.11.0/24"; }
d08_check(){ cat <<'EOF'
  docker exec clab-clos-h1 ping -c 2 172.16.12.10
  docker exec clab-clos-leaf1 ip route show 172.16.12.0/24    # 나가는 길은 있다
  docker exec clab-clos-leaf2 ip route show 172.16.11.0/24    # 돌아오는 길은?
EOF
}
d08_answer(){
  HR "h1 -> h2"; NS h1 ping -c 2 -W 1 172.16.12.10 | tail -2
  HR "leaf1 -> h2 랙 (나가는 길)"; X leaf1 ip route show 172.16.12.0/24
  HR "leaf2 -> h1 랙 (돌아오는 길)"; X leaf2 ip route show 172.16.11.0/24; echo "(비었으면 경로 없음)"
  cat <<'EOF'

[해설]
핑은 실패하는데 패킷은 h2 까지 잘 도착했다. 죽은 건 응답이다.
h2 가 172.16.11.10 으로 답하려는 순간 leaf2 가 "그런 주소 몰라"라며 버린다.
편도 단절은 양방향 단절보다 훨씬 찾기 어렵다 — 보내는 쪽 장비에는 아무 이상이 없기 때문이다.
그래서 통신 장애를 볼 때는 항상 "양쪽 다 상대 경로를 갖고 있는가"를 확인한다.
"저희 쪽은 정상입니다" 라는 말이 왜 위험한지 보여주는 케이스.
EOF
}
d08_restore(){ C leaf1 "router bgp 65011" "address-family ipv4 unicast" "network 172.16.11.0/24"; }

d09_title(){ echo "스파인에서 경로 하나만 걸러내기"; }
d09_ask(){ cat <<'EOF'
spine1 이 leaf4 의 프리픽스(172.16.14.0/24)만 받지 않도록 필터를 걸었다.
spine2 는 정상이다.

  Q1. h1 -> h4 통신은 끊길까?
  Q2. leaf1 이 보는 172.16.14.0/24 의 넥스트홉은 몇 개가 될까?
EOF
}
d09_inject(){
  C spine1 "ip prefix-list PL-L4 seq 5 permit 172.16.14.0/24" \
           "route-map RM-DROP-L4 deny 10" "match ip address prefix-list PL-L4" \
           "route-map RM-DROP-L4 permit 20" \
           "router bgp 65001" "address-family ipv4 unicast" "neighbor FABRIC route-map RM-DROP-L4 in"
  V spine1 "clear bgp * soft in" >/dev/null 2>&1
  sleep 3
}
d09_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
  docker exec clab-clos-spine1 vtysh -c "show ip bgp 172.16.14.0/24"
  docker exec clab-clos-h1 ping -c 3 172.16.14.10
EOF
}
d09_answer(){
  HR "leaf1 이 보는 172.16.14.0/24"; X leaf1 ip route show 172.16.14.0/24
  HR "spine1 이 보는 172.16.14.0/24 (없어야 정상)"; V spine1 "show ip bgp 172.16.14.0/24" 2>&1 | tail -4
  HR "h1 -> h4"; NS h1 ping -c 3 -W 1 172.16.14.10 | tail -2
  cat <<'EOF'

[해설]
안 끊긴다. 넥스트홉만 2개 -> 1개(spine2 방향)로 줄었다.
Clos 는 경로가 여러 개라서 "한 스파인의 설정 실수"를 통신 장애가 아니라 용량 감소로 바꿔놓는다.
반대로 말하면 이런 실수는 아무도 모르게 몇 달을 살아남는다 — 아무 알람도 안 울린다.
그래서 패브릭 운영에서는 "통신되나?" 가 아니라 "경로 개수가 설계값인가?" 를 감시한다.
check.sh 2번 항목이 nexthop 개수를 세는 이유가 바로 이것.
EOF
}
d09_restore(){
  C spine1 "router bgp 65001" "address-family ipv4 unicast" "no neighbor FABRIC route-map RM-DROP-L4 in"
  C spine1 "no route-map RM-DROP-L4 deny 10" "no route-map RM-DROP-L4 permit 20" "no ip prefix-list PL-L4"
  V spine1 "clear bgp * soft in" >/dev/null 2>&1
}

d10_title(){ echo "내 타이머만 늘리면 어떻게 될까"; }
d10_ask(){ cat <<'EOF'
leaf1 에서만 BGP 타이머를 timers 3 9 에서 timers 60 180 으로 바꾸고 세션을 다시 맺었다.
spine1 과 spine2 는 여전히 3 9 다.

  Q1. leaf1 의 실제 hold time 은 180초가 될까, 9초가 될까?
  Q2. 그 값은 누가 정하는 걸까?
EOF
}
d10_inject(){
  C leaf1 "router bgp 65011" "neighbor FABRIC timers 60 180"
  V leaf1 "clear bgp *" >/dev/null 2>&1
  sleep 12
}
d10_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp neighbors 10.1.1.0" | grep -i "hold time"
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp summary"
EOF
}
d10_answer(){
  HR "leaf1 이 요청한 값 vs 실제 협상된 값"; V leaf1 "show ip bgp neighbors 10.1.1.0" | grep -iE "hold time|keepalive interval" | head -6
  HR "세션 상태"; V leaf1 "show ip bgp summary" | grep -E "Neighbor|10\.1\."
  cat <<'EOF'

[해설]
180초를 요구했는데 실제로는 9초로 굳는다.
BGP 는 양쪽이 제시한 hold time 중 "더 작은 쪽"을 쓴다 (RFC 4271). 협상이 아니라 규칙이다.
그래서 타이머 튜닝은 반드시 양쪽 다 바꿔야 의미가 있다. 한쪽만 바꾸면 아무 일도 안 일어난다.
"타이머 늘려놨는데 왜 그대로죠" 의 답이 여기 있다.
짧은 쪽이 이긴다는 건 안전한 설계이기도 하다 — 한쪽이 실수로 느리게 잡아도 장애 감지가 늦어지지 않는다.
EOF
}
d10_restore(){
  C leaf1 "router bgp 65011" "neighbor FABRIC timers 3 9"
  V leaf1 "clear bgp *" >/dev/null 2>&1
}

d11_title(){ echo "ECMP 를 끄면 무엇이 남나"; }
d11_ask(){ cat <<'EOF'
leaf1 의 maximum-paths 를 64 에서 1 로 줄였다. 링크도 세션도 전부 정상이다.

  Q1. 라우팅 테이블의 넥스트홉은 몇 개가 될까?
  Q2. 그런데 BGP 테이블(show ip bgp)에는 경로가 몇 개 보일까? 같을까 다를까?
EOF
}
d11_inject(){
  C leaf1 "router bgp 65011" "address-family ipv4 unicast" "maximum-paths 1"
  V leaf1 "clear bgp * soft in" >/dev/null 2>&1
  sleep 3
}
d11_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp 172.16.14.0/24"
EOF
}
d11_answer(){
  HR "커널 라우팅 테이블 (실제로 쓰는 길)"; X leaf1 ip route show 172.16.14.0/24
  HR "BGP 테이블 (알고는 있는 길)"; V leaf1 "show ip bgp 172.16.14.0/24" | tail -12
  cat <<'EOF'

[해설]
커널에는 1개만 내려가고, BGP 테이블에는 여전히 2개가 다 보인다.
"아는 것"과 "쓰는 것"이 다르다는 게 핵심이다.
BGP 는 두 경로를 다 받아두고 그중 best 하나만 고른다. maximum-paths 는
"best 와 똑같이 좋은 경로를 몇 개까지 같이 쓸까"를 정하는 값이고, 1이면 ECMP 가 사라진다.
용량이 절반이 되지만 통신은 멀쩡하니 아무도 모른다 — 9일차와 같은 종류의 조용한 사고.

참고: 이 랩이 eBGP 인데도 ECMP 가 되는 건 bestpath as-path multipath-relax 덕분이다.
AS 번호가 서로 달라도(65001 vs 65002) 길이만 같으면 같이 쓰라는 뜻. 이게 없으면 1개만 남는다.
EOF
}
d11_restore(){
  C leaf1 "router bgp 65011" "address-family ipv4 unicast" "maximum-paths 64"
  V leaf1 "clear bgp * soft in" >/dev/null 2>&1
}

d12_title(){ echo "AS-path 를 길게 만들어 한쪽으로 몰기"; }
d12_ask(){ cat <<'EOF'
spine2 가 리프들에게 광고할 때 자기 AS 번호를 3번 덧붙이도록(prepend) 했다.
경로 자체는 멀쩡하다. 그냥 "멀어 보이게" 만든 것이다.

  Q1. leaf1 의 172.16.14.0/24 넥스트홉은 몇 개가 될까?
  Q2. 11일차(maximum-paths 1)와 결과가 같은데, 원인은 어떻게 구별할까?
EOF
}
d12_inject(){
  C spine2 "route-map RM-PREPEND permit 10" "set as-path prepend 65002 65002 65002" \
           "router bgp 65002" "address-family ipv4 unicast" "neighbor FABRIC route-map RM-PREPEND out"
  V spine2 "clear bgp * soft out" >/dev/null 2>&1
  sleep 3
}
d12_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp 172.16.14.0/24"
EOF
}
d12_answer(){
  HR "넥스트홉"; X leaf1 ip route show 172.16.14.0/24
  HR "BGP 테이블 — AS-path 길이를 비교하라"; V leaf1 "show ip bgp 172.16.14.0/24" | tail -14
  cat <<'EOF'

[해설]
1개만 남는다. 두 경로의 AS-path 길이가 3 대 5 로 달라졌기 때문이다.
multipath-relax 는 "AS 번호가 달라도 봐준다" 이지 "길이가 달라도 봐준다" 가 아니다. 길이는 반드시 같아야 한다.

11일차와 증상은 같지만 구별법이 있다.
- show ip bgp 에 경로가 2개 다 보이는데 AS-path 길이가 다르면 -> prepend 문제
- 길이가 같은데 커널에 1개만 내려가면 -> maximum-paths 문제
현업에서 prepend 는 "이 회선을 백업으로 쓰고 싶다"에 쓰는 정상 도구인데, 되돌리는 걸 잊으면 용량이 반이 된다.
EOF
}
d12_restore(){
  C spine2 "router bgp 65002" "address-family ipv4 unicast" "no neighbor FABRIC route-map RM-PREPEND out"
  C spine2 "no route-map RM-PREPEND permit 10"
  V spine2 "clear bgp * soft out" >/dev/null 2>&1
}

d13_title(){ echo "이웃이 경로를 너무 많이 보내면 (maximum-prefix)"; }
d13_ask(){ cat <<'EOF'
leaf1 에 "이웃 하나당 경로 3개까지만 받겠다"는 제한(maximum-prefix 3)을 걸었다.
지금 leaf1 은 각 스파인에서 8개씩 받고 있다. 즉 제한을 이미 넘긴 상태다.

  Q1. 넘친 만큼만 버리고 3개는 받을까, 아니면 세션 자체를 끊을까?
  Q2. 이건 라우터를 보호하려고 만든 기능이다. 그런데 걸어두면 어떤 새 위험이 생길까?
EOF
}
d13_inject(){
  C leaf1 "router bgp 65011" "address-family ipv4 unicast" "neighbor FABRIC maximum-prefix 3"
  V leaf1 "clear bgp *" >/dev/null 2>&1
  sleep 12
}
d13_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp summary"
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp neighbors 10.1.1.0" | grep -i -E "state|maximum|last reset"
  docker exec clab-clos-leaf1 sh -c "tail -10 /tmp/frr.log"
  docker exec clab-clos-h1 ping -c 2 172.16.12.10
EOF
}
d13_answer(){
  HR "leaf1 세션 상태 (State 칸을 보라)"; V leaf1 "show ip bgp summary" | grep -E "Neighbor|10\.1\."
  HR "끊긴 사유"; V leaf1 "show ip bgp neighbors 10.1.1.0" | grep -iE "BGP state|Maximum prefixes|Last reset" | head -4
  HR "leaf1 FRR 로그"; FRRLOG leaf1 12 | grep -iE "MAXPFX|NOTIFICATION|ADJCHANGE" | tail -5
  HR "h1 -> h2"; NS h1 ping -c 2 -W 1 172.16.12.10 2>&1 | tail -2
  cat <<'EOF'

[해설]
3개만 받고 나머지를 버리는 게 아니라 세션을 통째로 끊는다.
상태 칸에 Idle (PfxCt) 로 찍히고, 사유는 Cease/Maximum Number of Prefixes Reached 다.
게다가 이 설정을 peer-group 에 걸었기 때문에 스파인 2대와의 세션이 동시에 죽었다.
leaf1 은 2일차처럼 섬이 됐다 — 그것도 케이블 한 가닥 안 뽑고, 설정 한 줄로.

Q2 의 답이 이 실습의 핵심이다.
maximum-prefix 는 원래 좋은 기능이다. 이웃이 실수로 인터넷 전체 경로(90만 개)를 흘려보내면
내 라우터의 메모리가 터지는데, 그걸 막으려고 "이만큼 넘으면 관계를 끊어라"를 걸어둔다.
그런데 이 보호 장치 자체가 장애를 만든다. 한계값을 너무 빡빡하게 잡아두면
정상적인 증설(랙 추가, 서비스 대역 추가) 때 세션이 우수수 끊긴다.

그래서 실무에서는 두 단계로 쓴다.
  - maximum-prefix <값> warning-only   -> 끊지 말고 경고만 (보통 여기서 시작한다)
  - maximum-prefix <값> restart <분>    -> 끊되 몇 분 뒤 자동 재시도
그리고 한계값은 현재 개수의 2~3배로 잡는다. "지금 딱 맞게"는 사고를 부른다.

보안 하드닝 항목들이 대체로 이런 성질을 가진다 — 지키려던 걸 지키다가 스스로 멈춘다.
EOF
}
d13_restore(){
  C leaf1 "router bgp 65011" "address-family ipv4 unicast" "no neighbor FABRIC maximum-prefix 3"
  V leaf1 "clear bgp *" >/dev/null 2>&1
  sleep 3
}

# ─────────────────────────── 3주차: 포워딩과 커널 ───────────────────────────

d14_title(){ echo "라우터인데 안 넘겨준다 (ip_forward=0)"; }
d14_ask(){ cat <<'EOF'
leaf2 의 커널 설정 net.ipv4.ip_forward 를 0 으로 껐다.
BGP 도 링크도 전부 정상이다. 라우팅 테이블도 그대로다.

  Q1. leaf2 의 BGP 세션은 살아 있을까?
  Q2. h1 -> h2 핑은 될까?
EOF
}
d14_inject(){ X leaf2 sysctl -w net.ipv4.ip_forward=0 >/dev/null; }
d14_check(){ cat <<'EOF'
  docker exec clab-clos-leaf2 vtysh -c "show ip bgp summary"
  docker exec clab-clos-leaf2 ip route show 172.16.11.0/24
  docker exec clab-clos-h1 ping -c 3 172.16.12.10
  docker exec clab-clos-h2 ping -c 2 172.16.12.1     # 자기 게이트웨이는?
EOF
}
d14_answer(){
  HR "leaf2 BGP 세션 (멀쩡하다)"; V leaf2 "show ip bgp summary" | grep -E "Neighbor|10\.1\."
  HR "leaf2 라우팅 테이블도 멀쩡"; X leaf2 ip route show 172.16.11.0/24
  HR "h1 -> h2 (죽는다)"; NS h1 ping -c 3 -W 1 172.16.12.10 | tail -2
  HR "h2 -> 자기 게이트웨이 (된다)"; NS h2 ping -c 2 -W 1 172.16.12.1 | tail -2
  cat <<'EOF'

[해설]
BGP 도 정상, 라우팅 테이블도 정상, 그런데 통신은 죽는다. 모든 show 명령이 초록불인 장애다.

이유: 라우팅은 "길을 아는 것"이고 포워딩은 "실제로 넘겨주는 것"이다. 둘은 다른 기능이다.
- 컨트롤 플레인(BGP, 라우팅 테이블) = 지도를 그리는 부서
- 데이터 플레인(ip_forward, 칩) = 실제로 짐을 옮기는 부서
지도부서는 멀쩡한데 운송부서가 파업한 상황이라 지도만 봐서는 절대 못 찾는다.

찾는 법은 하나뿐이다 — 실제로 패킷을 흘려보는 것.
그래서 check.sh 에 3번 "서버 간 통신" 항목이 따로 있는 것이고,
현업 모니터링도 세션 감시만으로는 부족해서 합성 트래픽(synthetic probe)을 같이 돌린다.
EOF
}
d14_restore(){ X leaf2 sysctl -w net.ipv4.ip_forward=1 >/dev/null; }

d15_title(){ echo "서버가 기본 경로를 잃으면"; }
d15_ask(){ cat <<'EOF'
h1 의 default route 를 지웠다. IP 주소는 그대로 172.16.11.10/24 다.
네트워크 장비(leaf, spine)는 전부 정상이다.

  Q1. h1 -> h2 핑을 치면 어떤 에러가 뜰까? "timeout"? "unreachable"? 그냥 멈춤?
  Q2. h1 -> leaf1(172.16.11.1) 은 될까?
EOF
}
d15_inject(){ NS h1 ip route del default 2>/dev/null || true; }
d15_check(){ cat <<'EOF'
  docker exec clab-clos-h1 ip route
  docker exec clab-clos-h1 ping -c 2 172.16.11.1     # 같은 대역
  docker exec clab-clos-h1 ping -c 2 172.16.12.10    # 다른 대역
EOF
}
d15_answer(){
  HR "h1 라우팅 테이블"; NS h1 ip route
  HR "같은 대역 (172.16.11.1)"; NS h1 ping -c 2 -W 1 172.16.11.1 | tail -2
  HR "다른 대역 (172.16.12.10)"; NS h1 ping -c 2 -W 1 172.16.12.10 2>&1 | tail -3
  cat <<'EOF'

[해설]
같은 대역은 되고 다른 대역은 "Network unreachable" 이 즉시 뜬다.
중요한 건 "즉시" 다. 패킷이 나가지도 못하고 자기 커널이 바로 거절한 것이다.
타임아웃(기다리다 실패)과 unreachable(바로 실패)은 완전히 다른 신호다.

  - 즉시 unreachable  -> 내 쪽 문제. 라우팅 테이블부터 본다.
  - 기다리다 timeout  -> 나가긴 했는데 답이 없다. 중간이나 상대 쪽 문제다.

이 한 줄 구분이 장애 범위를 절반으로 줄여준다. 내일(16일차)은 같은 "안 됨"인데
증상이 정반대로 나오는 경우를 본다.
EOF
}
d15_restore(){ NS h1 ip route replace default via 172.16.11.1 2>/dev/null || true; }

d16_title(){ echo "기본 경로가 없는 주소를 가리키면"; }
d16_ask(){ cat <<'EOF'
h1 의 default route 를 172.16.11.1(진짜 게이트웨이)에서 172.16.11.99 로 바꿨다.
172.16.11.99 라는 장비는 세상에 없다. 대역은 맞다.

  Q1. 어제(15일차)처럼 즉시 unreachable 이 뜰까, 아니면 기다리다 timeout 될까?
  Q2. h1 의 ARP 테이블에는 뭐가 남을까?
EOF
}
d16_inject(){ NS h1 ip route replace default via 172.16.11.99; }
d16_check(){ cat <<'EOF'
  docker exec clab-clos-h1 ip route
  docker exec clab-clos-h1 ping -c 3 172.16.12.10
  ./scripts/in.sh h1 ip neigh                # ARP 상태를 보라
EOF
}
d16_answer(){
  HR "h1 라우팅 테이블"; NS h1 ip route
  HR "h1 -> h2"; NS h1 ping -c 3 -W 2 172.16.12.10 2>&1 | tail -3
  HR "h1 ARP 테이블"; NS h1 ip neigh
  cat <<'EOF'

[해설]
이번엔 unreachable 이 아니라 그냥 기다리다 죽는다. 라우팅 테이블에는 답이 있으니까
커널은 "172.16.11.99 한테 주면 되겠네" 까지 갔고, 그 다음 ARP 를 뿌렸는데 아무도 대답을 안 한 것이다.
ip neigh 에 FAILED 또는 INCOMPLETE 로 남아 있는 게 그 증거다.

15일차와 오늘의 차이가 실무에서 제일 자주 쓰는 판별식이다.
  - 경로가 아예 없다      -> 즉시 unreachable
  - 경로는 있는데 넥스트홉이 죽었다 -> ARP INCOMPLETE 로 남고 timeout

그래서 "핑이 그냥 멈춰요" 를 들으면 ip neigh 부터 본다. 여기가 INCOMPLETE 면
L3 설정 볼 필요 없이 L2 구간(게이트웨이 주소 오타, VLAN 불일치, 상대 장비 다운)만 보면 된다.
EOF
}
d16_restore(){ NS h1 ip route replace default via 172.16.11.1; }

d17_title(){ echo "MAC 주소 한 줄만 틀려도"; }
d17_ask(){ cat <<'EOF'
h1 의 ARP 테이블에 게이트웨이(172.16.11.1)의 MAC 을 엉뚱한 값(00:11:22:33:44:55)으로
고정(PERMANENT)해 박았다. IP 설정도 라우팅도 전부 정상이다.

  Q1. h1 -> h2 는 될까?
  Q2. leaf1 쪽에서 보면 h1 이 뭘 하고 있는 걸로 보일까?
EOF
}
d17_inject(){ NS h1 ip neigh replace 172.16.11.1 lladdr 00:11:22:33:44:55 dev eth1 nud permanent; }
d17_check(){ cat <<'EOF'
  ./scripts/in.sh h1 ip neigh
  docker exec clab-clos-h1 ip route              # 라우팅은 정상이다
  docker exec clab-clos-h1 ping -c 3 172.16.12.10
  docker exec clab-clos-leaf1 ip -s link show eth3 | tail -4   # 받긴 받는지
EOF
}
d17_answer(){
  HR "h1 ARP (틀린 MAC 이 PERMANENT 로 박혀 있다)"; NS h1 ip neigh
  HR "h1 라우팅은 정상"; NS h1 ip route
  HR "h1 -> h2"; NS h1 ping -c 3 -W 1 172.16.12.10 2>&1 | tail -3
  HR "leaf1 의 진짜 MAC (위의 틀린 값과 비교)"; X leaf1 ip -br link show eth3
  cat <<'EOF'

[해설]
IP 계층은 완벽하다. 그런데 통신이 안 된다.
패킷은 h1 의 랜카드에서 나가긴 나갔다. 다만 봉투에 적힌 수신인 MAC 이 세상에 없는 주소라
leaf1 이 "내 앞으로 온 게 아니네" 하고 무시한다. 아무도 에러를 안 낸다.

이게 L2 장애의 성질이다 — L3 도구(ping, traceroute, ip route)로는 아무것도 안 보인다.
그래서 순서가 중요하다. 통신이 안 될 때는 아래에서 위로 올라간다.
  1) 링크 UP 인가 (ip link)
  2) ARP 가 풀렸나, 그 MAC 이 진짜 상대 MAC 인가 (ip neigh + 상대의 ip link)
  3) 그 다음에야 라우팅 (ip route)
현업에서는 이 상황이 보통 오래된 ARP 캐시나 게이트웨이 이중화 전환(VRRP) 직후에 생긴다.
EOF
}
d17_restore(){ NS h1 ip neigh del 172.16.11.1 dev eth1 2>/dev/null || true; NS h1 ping -c 1 -W 1 172.16.11.1 >/dev/null 2>&1 || true; }

d18_title(){ echo "ECMP 해시 정책 0 과 1 의 차이"; }
d18_ask(){ cat <<'EOF'
오늘은 고장이 아니라 측정이다.
leaf1 의 fib_multipath_hash_policy 를 0(출발지/목적지 IP만 봄)으로 두고,
목적지가 같고 포트만 다른 흐름들이 어느 스파인으로 가는지 본다. 그다음 1(L4 포트까지 봄)로 바꿔 다시 본다.

  Q1. 정책 0 에서 포트를 바꾸면 경로가 달라질까?
  Q2. 웹서버 한 대에 접속이 몰리는 상황이면 어느 정책이 유리할까?
EOF
}
d18_inject(){ X leaf1 sysctl -w net.ipv4.fib_multipath_hash_policy=0 >/dev/null; }
d18_check(){ cat <<'EOF'
  # 정책 0 (지금 상태) — 포트만 바꿔가며 경로 확인
  for p in 1000 2000 3000 4000 5000; do
    docker exec clab-clos-leaf1 ip route get 172.16.14.10 ipproto tcp sport $p dport 80
  done

  # 정책 1 로 바꿔서 다시
  docker exec clab-clos-leaf1 sysctl -w net.ipv4.fib_multipath_hash_policy=1
EOF
}
d18_answer(){
  HR "정책 0 (IP만 본다) — 목적지 같으면 포트가 달라도 같은 길"
  X leaf1 sysctl -w net.ipv4.fib_multipath_hash_policy=0 >/dev/null
  for p in 1000 2000 3000 4000 5000 6000; do
    printf "  sport %-5s -> " $p
    X leaf1 ip route get 172.16.14.10 ipproto tcp sport $p dport 80 2>/dev/null | head -1 | awk '{print $3, $5}'
  done
  HR "정책 1 (포트까지 본다) — 흐름마다 갈린다"
  X leaf1 sysctl -w net.ipv4.fib_multipath_hash_policy=1 >/dev/null
  for p in 1000 2000 3000 4000 5000 6000; do
    printf "  sport %-5s -> " $p
    X leaf1 ip route get 172.16.14.10 ipproto tcp sport $p dport 80 2>/dev/null | head -1 | awk '{print $3, $5}'
  done
  cat <<'EOF'

[해설]
정책 0 에서는 여섯 흐름이 전부 같은 길로 간다. 출발지 IP 와 목적지 IP 가 같으니 해시값도 같기 때문이다.
정책 1 로 바꾸면 포트가 해시에 들어가서 흐름마다 길이 갈린다.

이 랩에서 실제로 측정했던 값: 40개 흐름을 정책 0 으로 흘렸더니 41 대 1 로 몰렸고,
정책 1 로 바꾸니 12 대 30 이 됐다. 링크는 2개인데 한 개만 일하고 있었던 것이다.

핵심: ECMP 는 "경로가 2개 있다"가 아니라 "흐름을 2개로 쪼갤 수 있다"여야 의미가 있다.
서버 한 대와 서버 한 대가 대량 전송을 하는 상황(백업, DB 복제)에서는 흐름이 하나라서
정책을 1로 해도 링크 하나만 쓴다. 그래서 대용량 전송은 일부러 세션을 여러 개로 쪼갠다.
EOF
}
d18_restore(){ X leaf1 sysctl -w net.ipv4.fib_multipath_hash_policy=0 >/dev/null; }

d19_title(){ echo "static 경로는 BGP 를 이긴다"; }
d19_ask(){ cat <<'EOF'
leaf1 에 172.16.14.0/24 로 가는 static 경로를 spine1 방향(10.1.1.0)으로만 박았다.
BGP 는 여전히 같은 대역을 스파인 2개로 광고받고 있다.

  Q1. 라우팅 테이블에는 누가 남을까? static? BGP? 둘 다?
  Q2. 통신은 될까?
EOF
}
d19_inject(){ X leaf1 ip route replace 172.16.14.0/24 via 10.1.1.0 dev eth1 metric 5; }
d19_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
  docker exec clab-clos-leaf1 vtysh -c "show ip route 172.16.14.0/24"
  docker exec clab-clos-h1 ping -c 2 172.16.14.10
EOF
}
d19_answer(){
  HR "커널 라우팅 테이블"; X leaf1 ip route show 172.16.14.0/24
  HR "FRR 이 보는 경로 (BGP 는 여전히 알고 있다)"; V leaf1 "show ip route 172.16.14.0/24" | tail -12
  HR "h1 -> h4"; NS h1 ping -c 2 -W 1 172.16.14.10 | tail -2
  cat <<'EOF'

[해설]
통신은 잘 된다. 그런데 ECMP 가 사라지고 spine1 한 길만 쓴다.
손으로 박은 경로가 이겼기 때문이다. 라우터는 같은 목적지에 여러 후보가 있으면
"이 정보를 얼마나 믿을 만한가" 점수(administrative distance)로 고른다. 작을수록 이긴다.
  kernel = 0,  static = 1,  eBGP = 20,  OSPF = 110
위 출력에 Known via "kernel", distance 0 이라고 찍힌 게 그것이다.
리눅스에서 ip route 로 직접 넣으면 커널 경로(0)가 되고, 라우터 CLI 의 static 문은 1이 된다.
둘 다 BGP(20)보다 훨씬 작으니 결과는 같다 — 사람이 넣은 것을 제일 믿는다.

문제는 이 "믿음"이 근거가 없다는 것이다. static 은 상대가 죽어도 모른다.
BGP 는 상대가 죽으면 경로를 회수하는데(4일차에서 봤다), static 은 링크만 살아 있으면
끝까지 버틴다. 그 결과가 내일(20일차) 나온다.
EOF
}
d19_restore(){ X leaf1 ip route del 172.16.14.0/24 via 10.1.1.0 dev eth1 metric 5 2>/dev/null || true; }

d20_title(){ echo "믿음이 근거를 이길 때 (블랙홀)"; }
d20_ask(){ cat <<'EOF'
어제 박은 static 경로(172.16.14.0/24 -> spine1)를 그대로 두고,
이번엔 spine1 을 먹통으로 만들었다 (포워딩을 끄고 프로세스를 얼렸다). 링크는 UP 이다.

  Q1. BGP 는 몇 초 뒤 spine1 이 죽은 걸 알아챌 것이다. 그러면 통신이 spine2 로 넘어갈까?
  Q2. 3일차(static 없이 spine1 만 얼림)와 결과가 어떻게 다를까?
EOF
}
d20_inject(){
  X leaf1 ip route replace 172.16.14.0/24 via 10.1.1.0 dev eth1 metric 5
  X spine1 sysctl -w net.ipv4.ip_forward=0 >/dev/null
  docker pause clab-clos-spine1 >/dev/null
  sleep 12
}
d20_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp summary"     # BGP 는 눈치챘다
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24       # 그런데 경로는?
  docker exec clab-clos-h1 ping -c 3 172.16.14.10                # h4 는?
  docker exec clab-clos-h1 ping -c 2 172.16.12.10                # h2 는?
EOF
}
d20_answer(){
  HR "BGP 는 spine1 이 죽은 걸 안다"; V leaf1 "show ip bgp summary" | grep -E "Neighbor|10\.1\."
  HR "그런데 172.16.14.0/24 경로는 여전히 spine1 방향"; X leaf1 ip route show 172.16.14.0/24
  HR "h1 -> h4 (static 이 걸린 대역: 죽는다)"; NS h1 ping -c 3 -W 1 172.16.14.10 | tail -2
  HR "h1 -> h2 (BGP 만 쓰는 대역: 산다)"; NS h1 ping -c 2 -W 1 172.16.12.10 | tail -2
  cat <<'EOF'

[해설]
BGP 는 제 할 일을 다 했다. 세션도 끊고 경로도 회수했다. 그런데 트래픽은 계속 죽은 스파인으로 간다.
static 경로가 여전히 이기고 있기 때문이다. 링크가 UP 이니 static 은 자기가 틀렸다는 걸 알 방법이 없다.

같은 장비에서 h2 로는 잘 가고 h4 로만 안 간다 — 이게 블랙홀의 전형적인 모습이다.
"일부 대역만 안 돼요" 를 들으면 static 경로부터 의심한다.

교훈: static 경로는 편해 보이지만 장애 복구 능력을 스스로 포기하는 선택이다.
꼭 써야 하면 상태를 감시하는 형태로 써야 한다 (예: track/IP SLA, 또는 FRR 의 nexthop 검증).
20일 중에 제일 중요한 날이 오늘이라고 봐도 된다.
EOF
}
d20_restore(){
  docker unpause clab-clos-spine1 >/dev/null 2>&1 || true
  X spine1 sysctl -w net.ipv4.ip_forward=1 >/dev/null
  X leaf1 ip route del 172.16.14.0/24 via 10.1.1.0 dev eth1 metric 5 2>/dev/null || true
}

# ─────────────────────────── 4주차: 눈으로 보기 ───────────────────────────

d21_title(){ echo "BGP 가 살아 있다고 말하는 소리 듣기"; }
d21_ask(){ cat <<'EOF'
오늘은 고장 없이 관찰만 한다.
leaf1 의 eth1(spine1 방향)에서 BGP 가 쓰는 TCP 179 번 포트를 12초간 엿듣는다.

  Q1. 아무 일도 안 일어나는 평상시에 패킷이 오갈까? 온다면 몇 초 간격일까?
  Q2. 그 간격은 어디서 정해진 값일까?
EOF
}
d21_inject(){ :; }
d21_check(){ cat <<'EOF'
  # 컨테이너 안에는 tcpdump 가 없어서 호스트의 tcpdump 를 컨테이너 네트워크에 꽂아 쓴다
  # (in.sh 가 그걸 해준다. 어떻게 되는 건지는 scripts/in.sh 주석에 적어뒀다)
  ./scripts/in.sh leaf1 tcpdump -i eth1 -n -tttt -c 8 tcp port 179

  docker exec clab-clos-leaf1 vtysh -c "show ip bgp neighbors 10.1.1.0" | grep -i "hold time"
EOF
}
d21_answer(){
  HR "eth1 에서 BGP 패킷 12초간 엿듣기"
  TD leaf1 -i eth1 -n -tttt -c 8 tcp port 179 2>/dev/null || echo "  (패킷이 안 잡히면 12초 안에 keepalive 가 안 온 것 — 다시 실행해보자)"
  HR "협상된 타이머"; V leaf1 "show ip bgp neighbors 10.1.1.0" | grep -iE "hold time|keepalive interval" | head -4
  cat <<'EOF'

[해설]
아무 변화가 없어도 3초마다 작은 패킷(19바이트짜리 KEEPALIVE)이 오간다.
이 랩의 설정이 timers 3 9 라서 keepalive 3초, hold 9초다.
규칙은 단순하다 — keepalive 는 hold 의 1/3 로 잡는다. 세 번 놓쳐야 죽었다고 판정하는 것이다.

이게 왜 중요하냐: 네트워크는 "조용하면 정상"이 아니라 "계속 살아 있다고 말해줘야 정상"이다.
말이 끊기면 죽은 걸로 친다. 그래서 링크가 살아 있어도(3일차) 세션이 죽을 수 있는 것이다.
반대로 이 keepalive 자체가 CPU 와 대역폭을 먹기 때문에 무한정 짧게 할 수는 없다.
그 딜레마의 답이 BFD 고, 26일차에 켜본다.
EOF
}
d21_restore(){ :; }

d22_title(){ echo "첫 패킷을 끝까지 따라가기"; }
d22_ask(){ cat <<'EOF'
h1 의 ARP 캐시를 비우고, h1 -> h4 로 핑 한 발을 쏘면서 leaf1 의 서버쪽 포트(eth3)를 엿듣는다.

  Q1. 제일 먼저 나가는 패킷은 ICMP 일까, ARP 일까?
  Q2. h1 은 h4 의 MAC 을 물어볼까, leaf1 의 MAC 을 물어볼까? 왜?
EOF
}
d22_inject(){ NS h1 ip neigh flush dev eth1 2>/dev/null || true; }
d22_check(){ cat <<'EOF'
  ./scripts/in.sh leaf1 tcpdump -i eth3 -n -e -c 6 "arp or icmp" &
  sleep 1
  ./scripts/in.sh h1 ip neigh flush dev eth1
  docker exec clab-clos-h1 ping -c 2 172.16.14.10
  wait
EOF
}
d22_answer(){
  HR "leaf1 eth3 를 엿들으면서 h1 -> h4 핑 한 발"
  ( TD leaf1 -i eth3 -n -e -c 6 "arp or icmp" 2>/dev/null & sleep 1; NS h1 ip neigh flush dev eth1 2>/dev/null; NS h1 ping -c 2 -W 1 172.16.14.10 >/dev/null 2>&1; wait ) 2>/dev/null
  HR "h1 의 ARP 테이블 (누구 MAC 을 배웠나)"; NS h1 ip neigh
  cat <<'EOF'

[해설]
순서는 ARP 먼저, ICMP 나중이다. 그리고 h1 이 물어본 건 h4 의 MAC 이 아니라 leaf1 의 MAC 이다.

왜냐면 h1 은 172.16.14.10 이 자기 대역(172.16.11.0/24) 밖이라는 걸 알고,
"밖으로 나가는 건 전부 게이트웨이한테 준다" 는 규칙을 따르기 때문이다.
그래서 봉투(이더넷 헤더)의 수신인은 leaf1 의 MAC 이고, 편지(IP 헤더)의 수신인만 h4 다.
이 구간을 지날 때마다 봉투는 새로 쓰고 편지는 그대로 간다 — 이게 라우팅의 본질이다.

17일차(틀린 MAC 박기)가 왜 통신을 죽였는지도 여기서 설명된다.
편지는 완벽했는데 봉투의 수신인이 틀렸던 것이다.
EOF
}
d22_restore(){ :; }

d23_title(){ echo "패킷을 안 쏘고 경로 물어보기"; }
d23_ask(){ cat <<'EOF'
ip route get 은 "이 패킷을 지금 보내면 어디로 나갈까"를 커널에게 물어보는 명령이다.
실제로 패킷을 쏘지 않고 커널의 판단만 받아본다.

  Q1. 장애 상황에서 ping 대신 이걸 쓰면 뭐가 좋을까?
  Q2. ECMP 가 걸린 목적지에 대해 물어보면 답이 몇 개 나올까?
EOF
}
d23_inject(){ :; }
d23_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 ip route get 172.16.14.10
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
  docker exec clab-clos-h1 ip route get 172.16.14.10
  docker exec clab-clos-leaf1 ip route get 8.8.8.8       # 패브릭이 모르는 주소
EOF
}
d23_answer(){
  HR "leaf1: 172.16.14.10 으로 지금 보내면?"; X leaf1 ip route get 172.16.14.10
  HR "leaf1 의 경로 후보는 2개인데"; X leaf1 ip route show 172.16.14.0/24
  HR "h1 에서 물어보면 (게이트웨이로 간다)"; NS h1 ip route get 172.16.14.10
  HR "패브릭이 모르는 주소 (8.8.8.8)"; X leaf1 ip route get 8.8.8.8 2>&1 | head -2
  cat <<'EOF'

[해설]
후보가 2개인데 답은 1개만 나온다. "고를 수 있는 길"이 아니라 "이 패킷이 실제로 갈 길"을 알려주기 때문이다.
ECMP 는 패킷마다 해시로 정해지니, 물어본 그 조건에서의 답 하나를 준다.

이게 장애 대응에서 강력한 이유:
  - ping 은 상대가 방화벽으로 막아두면 실패해도 원인을 모른다.
  - ip route get 은 내 커널의 판단만 보므로 "내 쪽 문제인가"를 즉시 가른다.
  - 상대를 건드리지 않으니 운영 중인 장비에서도 안전하게 칠 수 있다.

15/16일차에서 봤던 "즉시 unreachable" 과 "기다리다 timeout" 의 구분도
이 명령 하나로 패킷 안 쏘고 확인된다. 장애 났을 때 제일 먼저 치는 명령으로 삼을 만하다.
EOF
}
d23_restore(){ :; }

d24_title(){ echo "경로가 사라지는 순간을 로그로 보기"; }
d24_ask(){ cat <<'EOF'
leaf1 에 BGP 업데이트 디버그를 켜고, spine1 쪽 링크를 내렸다 올린다.
경로가 회수되고 다시 들어오는 과정이 로그에 그대로 찍힌다.

  Q1. 링크를 내리면 leaf1 은 "경로를 지운다"고 할까 "이웃이 죽었다"고 할까? 순서는?
  Q2. 링크를 다시 올리면 몇 초 만에 원래대로 돌아올까?
EOF
}
d24_inject(){ V leaf1 "debug bgp updates" >/dev/null 2>&1; }
d24_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 ip link set eth1 down
  sleep 3
  docker exec clab-clos-leaf1 ip link set eth1 up
  sleep 8
  docker exec clab-clos-leaf1 sh -c "tail -30 /tmp/frr.log"
EOF
}
d24_answer(){
  HR "링크 내림 -> 3초 -> 올림"
  X leaf1 ip link set eth1 down; sleep 3; X leaf1 ip link set eth1 up; sleep 10
  HR "leaf1 FRR 로그 (위에서 아래로 시간순)"; FRRLOG leaf1 30 | grep -viE "netlink-dp|Extended Error" | tail -16
  HR "복구 확인"; X leaf1 ip route show 172.16.14.0/24
  cat <<'EOF'

[해설]
순서가 핵심이다. "이웃이 죽었다"가 먼저고 "경로를 지운다"가 그 결과다.
BGP 는 경로를 개별로 감시하지 않는다. 이웃 단위로만 살았나 죽었나를 보고,
죽으면 그 이웃한테 받은 경로를 통째로 버린다.

그래서 한 이웃에서 10만 개 경로를 받고 있으면 이웃 하나 죽을 때 10만 개가 한꺼번에 흔들린다.
인터넷 백본에서 "BGP 컨버전스 시간"이 문제가 되는 이유가 이것이고,
이 랩이 리프당 프리픽스를 몇 개만 두고도 같은 구조를 보여주는 이유이기도 하다.

그리고 복구가 장애 감지보다 오래 걸린다는 것도 보인다.
끊는 건 즉시지만, 다시 맺으려면 TCP 연결 -> OPEN -> UPDATE 를 처음부터 다 해야 하기 때문이다.
EOF
}
d24_restore(){ V leaf1 "no debug bgp updates" >/dev/null 2>&1; X leaf1 ip link set eth1 up 2>/dev/null || true; }

d25_title(){ echo "show ip bgp 한 줄씩 읽기"; }
d25_ask(){ cat <<'EOF'
오늘은 명령 하나의 출력을 끝까지 읽는 날이다.
leaf1 에서 show ip bgp 172.16.14.0/24 를 치면 나오는 항목들의 뜻을 맞춰보자.

  Q1. 별표(*)와 부등호(>)는 각각 무슨 뜻일까?
  Q2. "multipath" 라고 표시된 줄과 안 붙은 줄의 차이는?
  Q3. AS-path 에 65001 하나만 있는데, 왜 65011 (자기 AS) 은 없을까?
EOF
}
d25_inject(){ :; }
d25_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp 172.16.14.0/24"
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp"
  docker exec clab-clos-leaf1 ip route show 172.16.14.0/24
EOF
}
d25_answer(){
  HR "테이블 뷰 — 왼쪽 기호(*, >, =)를 보라"; V leaf1 "show ip bgp" | head -14
  HR "leaf1: 172.16.14.0/24 상세"; V leaf1 "show ip bgp 172.16.14.0/24"
  HR "커널에 실제로 내려간 모습"; X leaf1 ip route show 172.16.14.0/24
  cat <<'EOF'

[해설]
읽는 법.
테이블 뷰(위)의 왼쪽 기호:
  *   valid — 이 경로는 쓸 수 있다 (넥스트홉이 도달 가능하다)
  >   best  — 여러 후보 중 이걸 골랐다
  =   multipath — best 와 동급이라 같이 쓴다 (이게 ECMP 다)
상세 뷰(아래)의 항목:
  multipath  같은 뜻. 이 표시가 사라지면 ECMP 가 깨진 것이다 (11, 12일차)
  AS-path    이 경로가 지나온 AS 목록. 오른쪽이 출발지다.
  Origin     경로가 어떻게 태어났는지 (i = network 문으로 넣음)
  best (...) 괄호 안이 "무엇으로 이겼는지" 다 (AS Path / Older Path 등)

Q3 의 답: AS-path 에 자기 AS 가 없는 이유는 "받을 때"가 아니라 "보낼 때" 붙이기 때문이다.
leaf4(65014) 가 만들어 spine1(65001) 에게 보낼 때 65014 가 붙고,
spine1 이 leaf1 에게 보낼 때 65001 이 붙는다. leaf1 이 이걸 또 남에게 보내면 그때 65011 이 붙는다.
자기 번호가 이미 들어 있는 경로를 받으면 "돌아온 경로"로 보고 버린다 — 이게 BGP 의 루프 방지 방법이다.
IGP 처럼 복잡한 계산 없이 AS 번호 목록 하나로 루프를 막는 게 BGP 가 인터넷 규모로 큰 이유다.

12일차의 prepend 가 왜 통했는지도 여기서 보인다. 이 목록에 자기 번호를 일부러 여러 번 넣어
"멀어 보이게" 만든 것뿐이다.
EOF
}
d25_restore(){ :; }

d26_title(){ echo "9초를 1초 아래로 (BFD)"; }
d26_ask(){ cat <<'EOF'
3일차에서 스파인을 얼렸을 때 감지에 약 9초가 걸렸다 (hold timer).
오늘은 BFD 를 켜고 같은 장애를 다시 준다. BFD 는 BGP 대신 아주 빠르게 살아있음을 확인하는 전용 프로토콜이다.

  Q1. 감지 시간이 얼마나 줄어들까?
  Q2. BGP 타이머를 그냥 0.3초로 줄이면 되지 않나? 왜 굳이 별도 프로토콜을 쓸까?
EOF
}
d26_inject(){
  if [ -x ./scripts/bfd-apply.sh ]; then bash ./scripts/bfd-apply.sh >/dev/null 2>&1 || true; fi
  sleep 5
}
d26_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 vtysh -c "show bfd peers brief"
  bash ./scripts/failover.sh freeze
EOF
}
d26_answer(){
  HR "BFD 세션"; V leaf1 "show bfd peers brief" 2>/dev/null | head -8
  HR "같은 장애 다시 주기 (약 40초 걸린다)"
  bash ./scripts/failover.sh freeze 2>&1 | tail -12
  cat <<'EOF'

[해설]
이 랩에서 측정했던 값: BFD 없이 7.6초 -> BFD 켜고 1초 안팎.
(실행할 때마다 조금씩 다르다. 중요한 건 정확한 숫자가 아니라 자릿수가 바뀌었다는 것이다)

BFD 는 켠 채로 둔다. 앞으로 남은 날들은 이 상태로 진행된다 — 실제 운영에서도 한 번 켜면 끄지 않는다.

Q2 의 답이 이 실습의 진짜 요점이다.
BGP 타이머를 0.3초로 줄이면 안 되는 이유가 있다. BGP 는 무거운 프로토콜이다.
TCP 위에서 돌고, 경로 계산을 하고, 라우팅 테이블을 갱신한다. 이걸 0.3초마다 시키면
장비 CPU 가 못 버티고, 잠깐 바쁜 것만으로도 세션이 끊어지는 오탐이 생긴다.

BFD 는 그래서 역할을 쪼갰다. "살아 있냐"만 묻는 아주 가벼운 패킷을 빠르게 주고받고,
죽었다 싶으면 BGP 에게 "저 이웃 죽었다"고 알려만 준다. 판단은 BFD 가, 대응은 BGP 가 한다.
감시와 판단을 분리하는 이 패턴은 네트워크 밖에서도 그대로 쓰인다 (헬스체크와 오케스트레이터의 관계).
EOF
}
d26_restore(){ :; }

# ─────────────────────────── 5주차: 종합 ───────────────────────────

d27_title(){ echo "절반만 죽는 장애"; }
d27_ask(){ cat <<'EOF'
spine1 의 ip_forward 를 껐다. 14일차와 같은 수법인데 이번엔 리프가 아니라 스파인이다.
BGP 는 전부 Established 다. 링크도 전부 UP 이다.

  Q1. h1 에서 h2, h3, h4 로 각각 핑을 쏘면 전부 죽을까, 일부만 죽을까?
  Q2. 왜 그럴까?
EOF
}
d27_inject(){ X spine1 sysctl -w net.ipv4.ip_forward=0 >/dev/null; }
d27_check(){ cat <<'EOF'
  bash ./scripts/check.sh
  docker exec clab-clos-h1 ping -c 3 172.16.12.10
  docker exec clab-clos-h1 ping -c 3 172.16.13.10
  docker exec clab-clos-h1 ping -c 3 172.16.14.10
EOF
}
d27_answer(){
  HR "check.sh 전체 점검"; bash ./scripts/check.sh 2>&1 | sed -n '1,22p'
  HR "목적지별 결과"
  local tgt
  for tgt in 172.16.12.10 172.16.13.10 172.16.14.10; do
    printf "  h1 -> %-15s : " "$tgt"
    if NS h1 ping -c 3 -W 1 "$tgt" >/dev/null 2>&1; then echo OK; else echo FAIL; fi
  done
  cat <<'EOF'

[해설]
일부만 죽는다. 어떤 목적지는 멀쩡하고 어떤 목적지는 완전히 안 된다.
ECMP 해시가 목적지 IP 로 길을 고르기 때문이다. spine1 으로 배정된 목적지만 죽고
spine2 로 배정된 목적지는 아무 영향이 없다.

이게 현업에서 제일 골치 아픈 유형인 이유:
  - 모니터링은 초록불이다 (BGP 12/12, 링크 전부 UP)
  - 사용자 신고는 "일부만 안 돼요" 로 들어온다
  - 재현이 잘 안 된다 (다른 서버에서 테스트하면 잘 된다)

찾는 법은 "안 되는 목적지" 들의 공통점을 찾는 것이다.
전부 같은 스파인을 타고 있다면 그 스파인이 범인이다.
확인은 각 스파인을 하나씩 통과시켜보면 된다 (해당 링크만 남기고 나머지를 잠깐 내려본다).
EOF
}
d27_restore(){ X spine1 sysctl -w net.ipv4.ip_forward=1 >/dev/null; }

d28_title(){ echo "겹친 장애 (하나씩은 괜찮은데)"; }
d28_ask(){ cat <<'EOF'
두 가지를 동시에 걸었다.
  (1) leaf1 의 eth1 링크 다운 (spine1 쪽 줄이 끊김)
  (2) spine2 의 ip_forward 를 0 으로
각각 따로 걸면 아무 문제도 안 생기는 장애들이다.

  Q1. h1 은 통신이 될까?
  Q2. leaf1 의 BGP 세션은 몇 개일까? 그 숫자만 보면 이상해 보일까?
EOF
}
d28_inject(){ X leaf1 ip link set eth1 down; X spine2 sysctl -w net.ipv4.ip_forward=0 >/dev/null; }
d28_check(){ cat <<'EOF'
  docker exec clab-clos-leaf1 vtysh -c "show ip bgp summary"
  docker exec clab-clos-leaf1 ip route show 172.16.12.0/24
  docker exec clab-clos-h1 ping -c 3 172.16.12.10
  docker exec clab-clos-h2 ping -c 3 172.16.13.10   # 다른 랙끼리는?
EOF
}
d28_answer(){
  HR "leaf1 BGP (1개 남았다 — 설계상 정상 범위처럼 보인다)"; V leaf1 "show ip bgp summary" | grep -E "Neighbor|10\.1\."
  HR "leaf1 경로 (있다)"; X leaf1 ip route show 172.16.12.0/24
  HR "leaf1 에 붙은 h1 은 전멸"
  local tgt
  for tgt in 172.16.12.10 172.16.13.10 172.16.14.10; do
    printf "  h1 -> %-15s : " "$tgt"
    if NS h1 ping -c 2 -W 1 "$tgt" >/dev/null 2>&1; then echo OK; else echo FAIL; fi
  done
  HR "다른 랙(h2)에서는 목적지에 따라 갈린다"
  for tgt in 172.16.13.10 172.16.14.10 172.16.11.10; do
    printf "  h2 -> %-15s : " "$tgt"
    if NS h2 ping -c 2 -W 1 "$tgt" >/dev/null 2>&1; then echo OK; else echo FAIL; fi
  done
  cat <<'EOF'

[해설]
h1 은 전멸이고, 다른 랙은 목적지에 따라 되는 것도 있고 안 되는 것도 있다.

차이가 왜 생기냐:
  - leaf1 은 spine1 쪽 줄이 끊겨서 남은 길이 spine2 하나뿐인데, 그 spine2 가 패킷을 안 넘긴다.
    선택지가 없으니 100% 죽는다.
  - leaf2/leaf3/leaf4 는 길이 아직 2개다. 그중 spine2 로 해시된 흐름만 죽는다.
    그래서 "어떤 건 되고 어떤 건 안 되는" 27일차 모습이 겹쳐 보인다.

leaf1 은 스파인 2개 중 1개가 끊겼을 뿐이라 "이중화가 동작 중" 인 정상 상태로 보인다.
그리고 spine2 의 BGP 는 멀쩡해서 다른 리프들도 spine2 를 정상으로 알고 있다.

이게 이중화의 함정이다. 이중화는 "장애 1건"을 견디도록 설계된 것이지 "장애 2건"이 아니다.
그래서 운영에서 제일 위험한 순간은 장애가 난 직후가 아니라, 장애 하나를 안 고치고 방치한 기간이다.
1일차의 링크 다운을 며칠 방치했다면 오늘 같은 일이 벌어진다.

교훈: 이중화된 구간의 장애는 "급하지 않다"가 아니라 "여유가 사라졌다"로 읽어야 한다.
9일차와 11일차의 조용한 사고들이 왜 무서운지도 여기서 이어진다.
EOF
}
d28_restore(){ X leaf1 ip link set eth1 up; X spine2 sysctl -w net.ipv4.ip_forward=1 >/dev/null; }

d29_title(){ echo "무작위 고장 하나 찾아내기"; }
d29_ask(){ cat <<'EOF'
오늘은 문제를 안 알려준다.
아래 다섯 가지 중 하나를 무작위로 골라 걸어놨다.
  a) 어딘가의 링크가 내려가 있다
  b) 어딘가의 BGP 이웃이 shutdown 되어 있다
  c) 어딘가의 ip_forward 가 꺼져 있다
  d) 어딘가에 잘못된 static 경로가 박혀 있다
  e) 어딘가의 서버가 기본 경로를 잃었다

  Q. check.sh 와 지금까지 배운 명령들로 어느 장비의 무슨 문제인지 찾아내라.
     (힌트: check.sh 의 네 항목 중 어디가 빨간불인지가 후보를 절반으로 줄여준다)
EOF
}
d29_inject(){
  local pick=$(( (RANDOM % 5) + 1 ))
  echo "$pick" > "$LAB_DIR/.day29-pick"
  case $pick in
    1) X leaf3 ip link set eth1 down ;;
    2) C leaf4 "router bgp 65014" "neighbor 10.1.2.6 shutdown" ;;
    3) X leaf3 sysctl -w net.ipv4.ip_forward=0 >/dev/null ;;
    4) X leaf2 ip route replace 172.16.13.0/24 via 10.1.1.2 dev eth1 metric 5 ;;
    5) NS h4 ip route del default 2>/dev/null || true ;;
  esac
}
d29_check(){ cat <<'EOF'
  bash ./scripts/check.sh
  # 그다음은 스스로. 아래가 도구 상자다.
  docker exec clab-clos-<노드> vtysh -c "show ip bgp summary"
  docker exec clab-clos-<노드> ip route
  docker exec clab-clos-<노드> ip link
  docker exec clab-clos-<노드> sysctl net.ipv4.ip_forward
  docker exec clab-clos-<노드> ip route get <목적지>
EOF
}
d29_answer(){
  local pick; pick=$(cat "$LAB_DIR/.day29-pick" 2>/dev/null || echo 0)
  HR "정답"
  case $pick in
    1) echo "  (a) leaf3 의 eth1 링크가 내려가 있었다 (spine1 쪽 업링크)" ;;
    2) echo "  (b) leaf4 에서 spine2(10.1.2.6) 이웃이 shutdown 되어 있었다" ;;
    3) echo "  (c) leaf3 의 ip_forward 가 0 이었다" ;;
    4) echo "  (d) leaf2 에 172.16.13.0/24 로 가는 잘못된 static 경로가 박혀 있었다" ;;
    5) echo "  (e) h4 의 default route 가 지워져 있었다" ;;
    *) echo "  (기록이 없다. day.sh 를 다시 돌리자)" ;;
  esac
  HR "지금 상태"; bash ./scripts/check.sh 2>&1 | sed -n '1,22p'
  cat <<'EOF'

[해설]
찾는 순서를 정리해두면 다음에 훨씬 빨라진다.

  1) check.sh 로 어느 층이 깨졌는지부터 본다
       세션 개수가 모자라다      -> b (또는 링크 문제인 a)
       세션은 정상인데 nexthop 이 모자라다 -> a, d
       전부 정상인데 통신만 안 된다 -> c, e
  2) 증상이 "한 방향만" 인지 "양방향" 인지 본다 (8일차)
  3) 즉시 실패인지 기다리다 실패인지 본다 (15/16일차)
  4) 안 되는 목적지들의 공통점을 찾는다 (27일차)

이 네 가지 질문이면 이 랩의 모든 장애가 두세 번 안에 좁혀진다.
실제 장애 대응도 구조는 똑같다 — 아는 명령의 개수가 아니라 자르는 순서가 실력이다.
EOF
}
d29_restore(){
  X leaf3 ip link set eth1 up 2>/dev/null || true
  C leaf4 "router bgp 65014" "no neighbor 10.1.2.6 shutdown" 2>/dev/null || true
  X leaf3 sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  X leaf2 ip route del 172.16.13.0/24 via 10.1.1.2 dev eth1 metric 5 2>/dev/null || true
  NS h4 ip route replace default via 172.16.14.1 2>/dev/null || true
  rm -f "$LAB_DIR/.day29-pick"
}

d30_title(){ echo "30일 정리"; }
d30_ask(){ cat <<'EOF'
오늘은 고장을 안 낸다. 랩을 정상 상태로 되돌리고 30일을 훑는다.

  Q1. 29일 동안 본 장애 중 "모든 show 명령이 초록불인데 통신은 죽는" 유형이 몇 개였나?
  Q2. 그중 check.sh 만으로 잡히는 건 몇 개고, 잡히지 않는 건 뭐였나?
EOF
}
d30_inject(){ :; }
d30_check(){ cat <<'EOF'
  bash ./scripts/check.sh
  cat /mnt/c/Users/*/Desktop/Claude/clos-fabric/docs/LOG.md
EOF
}
d30_answer(){
  HR "최종 점검"; bash ./scripts/check.sh 2>&1
  cat <<'EOF'

[30일 요약]

크게 네 덩어리를 봤다.

1) 이중화는 nexthop 개수로 보인다 (1, 2, 9, 11, 12일차)
   경로가 줄어도 통신은 멀쩡해서 아무도 모른다. 그래서 "되나?" 가 아니라 "설계값인가?" 를 본다.

2) 링크가 UP 이라고 살아 있는 게 아니다 (3, 14, 20, 27일차)
   조용한 장애가 시끄러운 장애보다 훨씬 오래 간다. 감시는 실제 패킷을 흘려봐야 한다.

3) 계층을 아래에서 위로 잘라 올라간다 (15, 16, 17, 22일차)
   링크 -> ARP -> 라우팅 -> 포워딩. 즉시 실패냐 기다리다 실패냐가 첫 갈림길이다.

4) 사람이 손으로 박은 것이 제일 위험하다 (7, 8, 12, 13, 19, 20일차)
   static, prepend, shutdown, 필터, maximum-prefix. 전부 정상 도구인데 잘못 쓰면 사고가 된다.
   특히 13일차처럼 "지키려고 넣은 설정"이 스스로 서비스를 멈추는 경우가 있다.

다음 단계 후보 (이 랩 위에 층을 쌓는 방향):
   - BGP 보안 하드닝 (GTSM, 최대 프리픽스 수 제한, 인증)
   - VLAN 과 L2 경계 다루기
   - MTU / MSS 함정 재현 (5일차 확장)
   - 쿠버네티스가 리프와 BGP 로 붙는 구성 (Calico / Cilium)

30일 기록은 docs/LOG.md 에 있다. 예측이 빗나갔던 날들만 다시 읽어보면
자기가 어디를 잘못 알고 있었는지가 그대로 보인다.
EOF
}
d30_restore(){ :; }
