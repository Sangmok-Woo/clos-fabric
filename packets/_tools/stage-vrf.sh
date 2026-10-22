#!/usr/bin/env bash
# VRF 구경 무대: leaf1·leaf4 뒤에 VRF마다 호스트 하나씩 (총 6대). 윈도우 Git Bash 에서 실행.
#   stage-vrf.sh up | down | ping
# k8s-ceph 랩이 떠 있어야 한다 (리프의 br110/br120/br130 에 VLAN 포트로 붙인다).
# 리프 설정 파일은 건드리지 않는다. 랩을 다시 배포하면 사라지므로 up 을 다시 돌린다.
#
#   VRF      VLAN  대역            MTU   leaf1         leaf4
#   PROD     110   10.10.16.0/24   1500  prod1 .11     prod4 .14     (리프 eth15)
#   STORAGE  120   10.10.20.0/24   9000  stor1 .11     stor4 .14     (리프 eth16)
#   REPL     130   10.10.24.0/24   9000  repl1 .11     repl4 .14     (리프 eth17)
set -e
export MSYS_NO_PATHCONV=1
cmd=${1:-}
case $cmd in up|down|ping) ;; *) sed -n 3p "$0"; exit 1 ;; esac

wsl -d Ubuntu -u root -- bash -s -- "$cmd" <<'EOF'
set -e
HOSTS="prod:eth15:110:10.10.16:1500 stor:eth16:120:10.10.20:9000 repl:eth17:130:10.10.24:9000"
IMG=clos-k8s-node:latest   # iputils 가 들어 있어 ping -M do 가 된다
pid() { docker inspect -f '{{.State.Pid}}' "clab-clos-$1"; }

up() {
  for l in 1 4; do
    docker exec clab-clos-leaf$l ip link show br110 >/dev/null 2>&1 || { echo "leaf$l 에 br110 없음 — k8s-ceph 랩부터 (k8s-ceph/up.sh)"; exit 1; }
    lp=$(pid leaf$l)
    for h in $HOSTS; do
      IFS=: read -r n port vlan net mtu <<< "$h"
      name=$n$l
      if docker inspect "clab-clos-$name" >/dev/null 2>&1; then echo "  $name 이미 있음"; continue; fi
      docker run -d --name "clab-clos-$name" --hostname "$name" --network none --label packets-stage=vrf \
        --entrypoint sleep "$IMG" infinity >/dev/null
      hp=$(pid "$name")
      ip link add "pk-$name" type veth peer name "ph-$name"
      ip link set "pk-$name" netns "$lp"; ip link set "ph-$name" netns "$hp"
      # 리프 쪽: 기존 서버 포트와 같은 모양 (포트 → VLAN 서브인터페이스 → VLAN 브리지)
      nsenter -t "$lp" -n sh -c "
        ip link set pk-$name name $port mtu $mtu up
        ip link add link $port name $port.$vlan type vlan id $vlan
        ip link set $port.$vlan mtu $mtu master br$vlan up"
      # 호스트 쪽: 태그 달고 나간다
      nsenter -t "$hp" -n sh -c "
        ip link set ph-$name name eth1 mtu $mtu up
        ip link add link eth1 name eth1.$vlan type vlan id $vlan
        ip link set eth1.$vlan mtu $mtu up
        ip addr add $net.1$l/24 dev eth1.$vlan
        ip route replace default via $net.1"
      echo "  $name  leaf$l:$port.$vlan  $net.1$l/24  mtu $mtu"
    done
  done
}

down() {
  ids=$(docker ps -aq --filter label=packets-stage=vrf)
  [ -n "$ids" ] && echo "$ids" | xargs docker rm -f >/dev/null   # 호스트 netns 가 사라지면 리프 쪽 veth·VLAN 도 같이 사라진다
  echo "  무대 철거 ($(echo "$ids" | grep -c .)대)"
}

check() {
  echo "| 확인 | 결과 |"; echo "|---|---|"
  t() { if docker exec "clab-clos-$2" sh -c "$3" >/dev/null 2>&1; then r=OK; else r=실패; fi; echo "| $1 | $r |"; }
  t "PROD prod1 → prod4"                prod1 "ping -c2 -W1 10.10.16.14"
  t "STORAGE stor1 → stor4"             stor1 "ping -c2 -W1 10.10.20.14"
  t "REPL repl1 → repl4"                repl1 "ping -c2 -W1 10.10.24.14"
  t "STORAGE 점보 9000 (-M do -s 8972)" stor1 "ping -c2 -W1 -M do -s 8972 10.10.20.14"
}

case $1 in up) up ;; down) down ;; ping) check ;; esac
EOF
