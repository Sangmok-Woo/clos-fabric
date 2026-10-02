#!/usr/bin/env bash
# ECMP 분산을 링크 양쪽에서 캡처해 센다. h1 → h4 로 목적지 포트만 다른 UDP 흐름 40개를 던지고,
# leaf1 의 스파인 방향 두 포트(eth1→spine1, eth2→spine2)에서 각각 캡처한다.
#   Phase p0    해시 정책 0 (L3: 출발지·목적지 IP)        흐름 40개
#   Phase p1a   해시 정책 1 (L4: 포트까지)                흐름 40개
#   Phase p1b   정책 1 그대로 같은 40개를 한 번 더          — 5-tuple 이 같은 흐름이 같은 링크로 가는가
#   Phase p3a/b 해시 정책 3 (필드 지정: 출발지·목적지 IP·프로토콜·포트) 두 번 — 헤더만 보는 해시
#   Phase p0ip  정책 0, 출발지 IP 8개로 ping 한 번씩       — IP 쌍이 다르면 정책 0 도 갈리는가
# 정책 1 은 패킷에 이미 L4 해시값(skb->hash)이 붙어 있으면 헤더를 다시 보지 않고 그 값을 쓴다.
# 그 값은 h1 의 소켓이 무작위로 정한 것이고 veth 가 리프까지 넘겨준다 → 같은 5-tuple 도 실행마다 링크가 바뀔 수 있다.
# 정책 3 은 지정한 헤더 필드만으로 해시를 계산한다. 실제 스위치의 5-tuple 해시와 같은 조건이다.
# leaf1 의 원래 해시 정책·필드는 되돌린다. h1 에 붙인 보조 IP 도 지운다.
set -u
. "$(dirname "$0")/../_tools/lab.sh"
SNAP=128
DST=172.16.14.10
FLOWS=40
PORTS=$(seq 5000 $((5000 + FLOWS - 1)) | tr '\n' ' ')
SRCS=$(seq 101 108 | sed 's/^/172.16.11./' | tr '\n' ' ')
ST=$HERE/state; rm -rf "$CAPDIR" "$ST"; mkdir -p "$CAPDIR" "$ST"
exec > >(tee "$CAPDIR/run-output.txt") 2>&1

dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_policy > "$ST/hash.orig"
dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_fields > "$ST/fields.orig"
dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_fields=0x37   # 정책 3 일 때만 쓰인다: src/dst IP, proto, src/dst port
policy() { dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_policy="$1"; }
# 출발지 포트도 고정한다(목적지 포트 + 1000). 그래야 두 번 던진 흐름의 5-tuple 이 완전히 같다
udp_flows() { dx h1 sh -c "for p in $PORTS; do (echo x | nc -u -w1 -p \$((p+1000)) $DST \$p >/dev/null 2>&1) & done; wait"; }
pings() { for s in $SRCS; do dx h1 ping -c1 -W1 -q -I "$s" $DST >/dev/null 2>&1; done; }

# 링크별로 무엇이 지나갔는지: udp → 목적지 포트 목록, icmp → 출발지 IP 목록
seen() {   # seen <pcap> udp|icmp
  if [ "$2" = udp ]; then tcpdump -nn -r "$1" udp 2>/dev/null | awk '{split($5,a,"."); sub(":","",a[5]); print a[5]}'
  else tcpdump -nn -r "$1" 'icmp[icmptype]==icmp-echo' 2>/dev/null | awk '{print $3}'; fi | sort -n | uniq
}
phase() {   # phase <이름> <정책> udp|icmp <설명>
  local tag=$1 pol=$2 kind=$3; shift 3
  say "Phase $tag — 해시 정책 $pol, $*"
  policy "$pol"
  if [ "$kind" = udp ]; then f="udp and dst host $DST and dst portrange 5000-5999"; else f="icmp and dst host $DST"; fi
  cap_start "$tag-leaf1-eth1" leaf1 eth1 $f
  cap_start "$tag-leaf1-eth2" leaf1 eth2 $f
  cap_wait 1
  if [ "$kind" = udp ]; then udp_flows; else pings; fi
  cap_stop >/dev/null
  seen "$CAPDIR/$tag-leaf1-eth1.pcap" $kind > "$ST/$tag.eth1"
  seen "$CAPDIR/$tag-leaf1-eth2.pcap" $kind > "$ST/$tag.eth2"
  printf '  eth1(→spine1) %3d    eth2(→spine2) %3d\n' "$(wc -l < "$ST/$tag.eth1")" "$(wc -l < "$ST/$tag.eth2")"
  [ "$kind" = icmp ] && { echo "  spine1 로 간 출발지: $(tr '\n' ' ' < "$ST/$tag.eth1")"; echo "  spine2 로 간 출발지: $(tr '\n' ' ' < "$ST/$tag.eth2")"; }
  return 0
}

say "준비 — leaf1 의 경로와 원래 해시 정책 ($(cat "$ST/hash.orig"))"
dx leaf1 vtysh -c "show ip route 172.16.14.0/24" | grep -E 'via|Known'
for s in $SRCS; do dx h1 ip addr add "$s/24" dev eth1 2>/dev/null; done

phase p0   0 udp  "목적지 포트만 다른 UDP 흐름 $FLOWS 개 (출발지 포트는 목적지+1000 고정)"
phase p1a  1 udp  "같은 흐름 $FLOWS 개"
phase p1b  1 udp  "같은 흐름 $FLOWS 개를 한 번 더"
say "p1a 와 p1b 비교 — 5-tuple 이 같은 흐름이 같은 링크로 갔나"
compare() {   # compare <phase a> <phase b> — 같은 목적지 포트가 같은 링크로 간 개수
  { sed 's/$/ 1/' "$ST/$1.eth1"; sed 's/$/ 2/' "$ST/$1.eth2"; } | sort > "$ST/cmp.a"
  { sed 's/$/ 1/' "$ST/$2.eth1"; sed 's/$/ 2/' "$ST/$2.eth2"; } | sort > "$ST/cmp.b"
  local same; same=$(comm -12 "$ST/cmp.a" "$ST/cmp.b" | wc -l)
  echo "  $FLOWS 개 중 같은 링크: $same  /  바뀐 링크: $((FLOWS - same))"
}
compare p1a p1b
phase p3a  3 udp  "같은 흐름 $FLOWS 개"
phase p3b  3 udp  "같은 흐름 $FLOWS 개를 한 번 더"
say "p3a 와 p3b 비교 — 5-tuple 이 같은 흐름이 같은 링크로 갔나"
compare p3a p3b
phase p0ip 0 icmp "출발지 IP 8개(172.16.11.101~108)에서 ping 한 번씩"

say "원복"
for s in $SRCS; do dx h1 ip addr del "$s/24" dev eth1 2>/dev/null; done
policy "$(cat "$ST/hash.orig")"
dx leaf1 sysctl -qw net.ipv4.fib_multipath_hash_fields="$(cat "$ST/fields.orig")"
echo "  leaf1 해시 정책 $(dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_policy) · 필드 $(dx leaf1 sysctl -n net.ipv4.fib_multipath_hash_fields), h1 주소 $(dx h1 ip -4 addr show eth1 | grep -c inet)개"
cap_stop
