#!/usr/bin/env bash
# 데이터센터가 "돌고 있는" 것처럼 보이게 트래픽을 계속 만든다.
# Wireshark 로 실시간 캡처하면서 구경하는 용도.
#
# 사용법:  ./scripts/traffic.sh          (Ctrl-C 로 중단)
#          ./scripts/traffic.sh 0.5      (간격 0.5초로 더 빠르게)
#
# 만드는 트래픽:
#   1) v1 -> v3   : 랙을 넘는 같은 서브넷 통신  => VXLAN 캡슐화됨 (볼거리)
#   2) h1 -> h2/3/4: 평범한 라우팅 통신         => 캡슐화 없음 (비교용)
#   3) 가끔 ARP 재해석, 가끔 없는 주소로 ARP    => 브로드캐스트 처리 구경
# 매번 새 ping 프로세스라 ICMP id 가 달라지고, 그래서 바깥 UDP 포트도 달라진다
# => 스파인 두 대로 번갈아 흩어지는 걸 볼 수 있다.
set -u
GAP=${1:-1}
D=docker
trap 'echo; echo "트래픽 중단."; exit 0' INT TERM

i=0
echo "트래픽 시작 (간격 ${GAP}초). Ctrl-C 로 중단."
while true; do
  i=$((i+1))

  # 1) VXLAN 을 타는 통신 — 크기를 바꿔가며 보낸다
  SZ=$(( 56 + (i % 5) * 200 ))
  $D exec clab-clos-v1 ping -c 2 -W 1 -s $SZ 10.10.10.33 >/dev/null 2>&1 &

  # 2) 평범한 라우팅 통신 (언더레이)
  T=$(( i % 3 ))
  case $T in
    0) $D exec clab-clos-h1 ping -c 1 -W 1 172.16.12.10 >/dev/null 2>&1 & ;;
    1) $D exec clab-clos-h1 ping -c 1 -W 1 172.16.13.10 >/dev/null 2>&1 & ;;
    2) $D exec clab-clos-h1 ping -c 1 -W 1 172.16.14.10 >/dev/null 2>&1 & ;;
  esac

  # 3) 10회마다 ARP 를 지워서 "누구세요?" 를 다시 보게 한다
  if [ $((i % 10)) -eq 0 ]; then
    $D exec clab-clos-v1 ip neigh flush all >/dev/null 2>&1 &
  fi

  # 4) 17회마다 없는 주소로 ARP -> 브로드캐스트(BUM) 가 어떻게 배달되는지
  if [ $((i % 17)) -eq 0 ]; then
    $D exec clab-clos-v1 ping -c 1 -W 1 10.10.10.99 >/dev/null 2>&1 &
  fi

  printf "\r보낸 묶음: %d   " "$i"
  sleep "$GAP"
done
