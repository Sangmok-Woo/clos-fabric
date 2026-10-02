#!/usr/bin/env bash
# 서버 6대에 챕터에서 쓰는 도구를 설치한다 (랩을 새로 띄울 때마다 한 번).
# curl(HTTP 클라이언트) busybox-extras(httpd) iperf3(트래픽) — h4 에는 dnsmasq(DNS 서버)도.
set -eu
. "$(dirname "$0")/lab.sh"
for h in h1 h2 h3 h4 v1 v3; do
  extra=""; [ "$h" = h4 ] && extra=dnsmasq
  apk_add "$h" curl busybox-extras iperf3 $extra && echo "  $h 설치 완료"
done
# 각 서버에 작은 웹 페이지 + httpd(:80)
for h in h1 h2 h3 h4; do
  dx "$h" sh -c "mkdir -p /srv/www && echo 'hello from $h' > /srv/www/index.html && dd if=/dev/urandom of=/srv/www/big.bin bs=1M count=20 2>/dev/null; pkill -x httpd; httpd -p 80 -h /srv/www"
done
echo "  h1~h4 httpd :80 (index.html, big.bin 20MB)"
