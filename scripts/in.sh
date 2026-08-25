#!/usr/bin/env bash
# 호스트의 도구를 컨테이너의 네트워크 안에서 실행한다.
#
#   ./scripts/in.sh h1 ping -c 2 -s 1472 -M do 172.16.14.10
#   ./scripts/in.sh h1 ip neigh
#   ./scripts/in.sh leaf1 tcpdump -i eth1 -n -c 5 tcp port 179
#
# 왜 필요하냐:
#   이 랩의 서버(h1~h4)는 alpine 이라 ping 과 ip 명령이 busybox 축소판이다.
#   -M do 같은 옵션도 없고 ip neigh replace 도 없다. tcpdump 는 아예 없다.
#   그런데 컨테이너의 "네트워크"라는 건 결국 리눅스 네임스페이스 하나일 뿐이라,
#   호스트의 멀쩡한 도구를 그 네임스페이스 안으로 들여보내면 그대로 쓸 수 있다.
#   docker exec 는 컨테이너 안의 프로그램을 실행하고, 이건 호스트 프로그램을
#   컨테이너의 네트워크에서 실행한다. 프로그램은 호스트 것, 네트워크는 컨테이너 것.
set -u
[ $# -lt 2 ] && { sed -n '2,8p' "$0"; exit 1; }
NODE=$1; shift
PID=$(docker inspect -f '{{.State.Pid}}' "clab-clos-$NODE" 2>/dev/null) || {
  echo "clab-clos-$NODE 를 찾을 수 없다."; exit 1; }
exec nsenter -t "$PID" -n "$@"
