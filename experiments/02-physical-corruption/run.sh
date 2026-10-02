#!/usr/bin/env bash
# 물리 계층 불량 흉내. leaf3 → h3 케이블이 상했다고 치고 leaf3:eth3 송신에 tc netem 을 건다.
#   Phase corrupt  corrupt 4%    — 비트가 뒤집힌 프레임
#   Phase loss     loss gemodel 2% 30% — 몰려서 사라지는 간헐 손실 (Gilbert-Elliott: 정상→불량 2%, 불량→정상 30%)
#                  ※ 이 커널(WSL 6.6)에서는 netem 의 `loss 5%`(무작위 손실)가 하나도 버리지 않았다. gemodel 은 동작한다
# 각 Phase 에서 h3 가 h1 의 파일 2MB 를 받는다 (데이터는 h1 → … → leaf3 → [불량 케이블] → h3).
# 캡처 지점:
#   h1:eth1  보내는 쪽 — 케이블 앞. 깨끗한 원본과 재전송이 보인다
#   h3:eth1  받는 쪽   — 케이블 뒤. 깨진 프레임과 빈자리가 보인다
# veth 는 받은 패킷의 체크섬을 검사하지 않고 믿는다(rx-checksumming). 진짜 NIC 이라면 FCS 에서
# 버렸을 프레임이므로, h3 에서 rx 체크섬 오프로드를 꺼 커널이 직접 검사하게 한다.
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=0                       # 체크섬을 검사하려면 패킷 전체가 필요하다
URL=http://172.16.11.10/big.bin
rm -rf "$CAPDIR"; mkdir -p "$CAPDIR"

get() {   # 2MB 받아서 md5 비교
  dx h3 sh -c "curl -s --max-time 30 -r 0-2097151 -o /tmp/got $URL -w '%{size_download}B %{time_total}s  md5 '; md5sum /tmp/got | cut -c1-12"
}
n() { nsx "$1" nstat -az "$2" | awk -v k="$2" '$1==k{print $2}'; }
snap() { echo "$(n h3 TcpInCsumErrors) $(n h3 IpInHdrErrors) $(n h1 TcpRetransSegs)"; }
counters() {   # 직전 snap 이후 늘어난 만큼
  set -- $1 $(snap)
  echo "  늘어난 값: h3 TCP 체크섬 오류 $(( $4 - $1 )) · h3 IP 헤더 오류 $(( $5 - $2 )) · h1 재전송 $(( $6 - $3 ))"
}

dx h3 ethtool -K eth1 rx off >/dev/null
say "기준값 (장애 없음)"
echo "  원본 md5 $(dx h1 sh -c 'head -c 2097152 /srv/www/big.bin | md5sum | cut -c1-12')"
b=$(snap); echo "  $(get)"; counters "$b"

for phase in "corrupt:corrupt 4%" "loss:loss gemodel 2% 30%"; do
  tag=${phase%%:*}; spec=${phase#*:}
  say "Phase $tag — leaf3:eth3 netem $spec"
  nsx leaf3 tc qdisc replace dev eth3 root netem $spec
  cap_start "$tag-h1-eth1" h1 eth1 tcp port 80 or icmp
  cap_start "$tag-h3-eth1" h3 eth1 tcp port 80 or icmp
  cap_wait 1
  b=$(snap)
  echo "  ping h1→h3 50회 (0.1초 간격): $(dx h1 ping -c 50 -i 0.1 -q 172.16.13.10 | grep -o '[0-9]*% packet loss')"
  echo "  2MB 전송: $(get)"
  counters "$b"
  echo "  netem 이 버린 패킷: $(nsx leaf3 tc -s qdisc show dev eth3 | grep -o 'dropped [0-9]*' | head -1)"
  cap_stop
  nsx leaf3 tc qdisc del dev eth3 root
done
dx h3 ethtool -K eth1 rx on >/dev/null
say "복구 확인"; nsx leaf3 tc qdisc show dev eth3; dx h3 ethtool -k eth1 | grep rx-checksumming
