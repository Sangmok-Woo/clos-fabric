#!/usr/bin/env bash
# 실험 준비. BGP/EVPN/주소는 건드리지 않고 MTU·해시정책·HTTP 서버만 얹는다.
# 원래 값은 state/ 에 적어두고 teardown.sh 가 그대로 되돌린다.
# 사용법: ./setup.sh            (evpn-apply.sh 가 끝난 랩에서)
#         SIZE_MB=1024 ./setup.sh
set -eu
. "$(dirname "$0")/lib.sh"
SIZE_MB=${SIZE_MB:-1024}
mkdir -p "$STATE" "$PCAP"

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

echo "=== 5) 호스트에 도구 설치 (curl, httpd, ss, ping -M) ==="
# WSL 게이트웨이 resolver 가 Docker Hub/alpine CDN 을 자주 못 푼다 → 이 두 컨테이너만 8.8.8.8
for h in $CLIENT $SERVER; do
  docker exec "$(c $h)" sh -c 'echo nameserver 8.8.8.8 > /etc/resolv.conf'
  docker exec "$(c $h)" sh -c 'apk add -q --no-progress curl busybox-extras iproute2-ss iputils-ping' \
    || { echo "  $h: apk 실패. DNS 문제면 WSL /etc/resolv.conf 를 8.8.8.8 로"; exit 1; }
done

echo "=== 6) 테스트 파일 ==="
docker exec "$(c $SERVER)" mkdir -p /srv
if ! docker exec "$(c $SERVER)" test -f /srv/video-large.bin; then
  echo "  video-large.bin ${SIZE_MB}MB 생성 (urandom, 1분쯤)"
  docker exec "$(c $SERVER)" dd if=/dev/urandom of=/srv/video-large.bin bs=1M count="$SIZE_MB" 2>/dev/null
fi
SMALL=$HERE/files/video-small.mp4
if [ -f "$SMALL" ]; then
  docker cp -q "$SMALL" "$(c $SERVER)":/srv/video-small.mp4
else
  echo "  (files/video-small.mp4 없음 — 윈도우에서 make-video.cmd 먼저)"
fi
docker exec "$(c $SERVER)" sh -c 'cd /srv && md5sum *' | tee "$STATE/md5.txt"

echo "=== 7) HTTP 서버 (양쪽 호스트, :$PORT) ==="
for h in $CLIENT $SERVER; do
  docker exec "$(c $h)" sh -c "mkdir -p /srv; pkill -x httpd; httpd -p $PORT -h /srv"
done
docker exec "$(c $CLIENT)" curl -s -o /dev/null -w "  v1 -> v3 HEAD %{http_code}\n" -I "http://$SERVER_IP:$PORT/video-large.bin"

echo
echo "준비 끝. 확인: ./ifmap.sh"
