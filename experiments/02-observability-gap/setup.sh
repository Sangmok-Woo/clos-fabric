#!/usr/bin/env bash
# 실험 준비. BGP/EVPN/주소는 건드리지 않고 MTU·해시정책·HTTP 서버만 얹는다.
# 원래 값은 state/ 에 적어두고 teardown.sh 가 그대로 되돌린다.
# 사용법: ./setup.sh            (evpn-apply.sh 가 끝난 랩에서)
set -eu
. "$(dirname "$0")/lib.sh"
mkdir -p "$STATE"

echo "=== 1) 원래 값 기록 ==="
if [ ! -f "$STATE/mtu.orig" ]; then
  for p in $FABRIC_IFS $OVERLAY_IFS; do echo "$p $(mtu_of "$p")"; done > "$STATE/mtu.orig"
  for n in leaf1 leaf2 leaf3 leaf4; do
    echo "$n $(docker exec "$(c $n)" sysctl -n net.ipv4.fib_multipath_hash_policy)"
  done > "$STATE/hash.orig"
  echo "  state/mtu.orig, state/hash.orig 저장"
else
  echo "  이미 기록돼 있음 (재실행). 덮어쓰지 않는다"
fi

echo "=== 2) 언더레이 MTU $UNDERLAY_MTU 로 통일 ==="
for p in $FABRIC_IFS; do set_mtu "$p" $UNDERLAY_MTU; done
echo "  패브릭 링크 16개"

echo "=== 3) 오버레이 MTU $OVERLAY_MTU (VXLAN 50B 여유) ==="
# 브리지는 포트 MTU를 따라가므로 포트 먼저, 브리지 나중
for p in leaf1:eth4 leaf1:vni10010 leaf3:eth4 leaf3:vni10010 leaf1:br10010 leaf3:br10010 v1:eth1 v3:eth1; do
  set_mtu "$p" $OVERLAY_MTU
done

echo "=== 4) ECMP 해시를 L4(5-튜플)로 ==="
# 정책 0(IP만)이면 leaf1<->leaf3 VXLAN 은 바깥 IP가 늘 같아 스파인 한 대로만 간다.
# VXLAN 바깥 UDP 소스포트가 안쪽 플로우 해시라서, 정책 1이어야 플로우별로 갈린다.
for n in leaf1 leaf2 leaf3 leaf4; do
  docker exec "$(c $n)" sysctl -qw net.ipv4.fib_multipath_hash_policy=1
done

echo "=== 5) 호스트에 도구 설치 (curl, httpd) ==="
# WSL 게이트웨이 resolver 가 Docker Hub/alpine CDN 을 자주 못 푼다 → 이 두 컨테이너만 8.8.8.8
for h in $CLIENT $SERVER; do
  docker exec "$(c $h)" sh -c 'echo nameserver 8.8.8.8 > /etc/resolv.conf'
  docker exec "$(c $h)" sh -c 'apk add -q --no-progress curl busybox-extras iproute2-ss iputils-ping' \
    || { echo "  $h: apk 실패. DNS 문제면 WSL /etc/resolv.conf 를 8.8.8.8 로"; exit 1; }
done

echo "=== 6) 테스트 파일 $FILE ==="
docker exec "$(c $SERVER)" mkdir -p /srv
SMALL=$HERE/files/$FILE
if [ -f "$SMALL" ]; then
  docker cp -q "$SMALL" "$(c $SERVER)":/srv/$FILE
  echo "  files/$FILE 복사"
elif ! docker exec "$(c $SERVER)" test -f /srv/$FILE; then
  # 재생 가능한 영상이 필요 없으면 같은 크기의 난수 파일로 충분하다
  echo "  files/$FILE 없음 → 같은 크기(${FILE_BYTES}B) 난수 파일 생성"
  docker exec "$(c $SERVER)" sh -c "head -c $FILE_BYTES /dev/urandom > /srv/$FILE"
fi
docker exec "$(c $SERVER)" sh -c "cd /srv && md5sum $FILE" | tee "$STATE/md5.txt"

echo "=== 7) HTTP 서버 (양쪽 호스트, :$PORT) ==="
for h in $CLIENT $SERVER; do
  docker exec "$(c $h)" sh -c "mkdir -p /srv; pkill -x httpd; httpd -p $PORT -h /srv"
done
docker exec "$(c $CLIENT)" curl -s -o /dev/null -w "  v1 -> v3 HEAD %{http_code}\n" -I "http://$SERVER_IP:$PORT/$FILE"

echo
echo "준비 끝. 다음: ./probe.sh"
