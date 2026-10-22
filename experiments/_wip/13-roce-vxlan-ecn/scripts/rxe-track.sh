#!/usr/bin/env bash
# 트랙 A 점검 — rxe 는 ECN 에 반응하는가. 사용: rxe-track.sh [초=10]
# e1 (leaf1) → e3 (leaf3) ib_write_bw 를 스파인 병목(100Mbit, RED/ECN)으로 보낸다. 같은 VNI 안이라 VXLAN 을 탄다.
#   tclass 2 : GRH traffic class = ECT(0). 스파인이 CE 를 찍는다 → e3 가 CNP(opcode 0x81)를 보내는가, e1 이 줄이는가
#   tclass 0 : 기본값 Not-ECT. RED 는 마킹 대신 버린다 → NAK 과 Go-Back-N 재전송
# 캡처: leaf3 eth1 in (바깥 헤더), leaf3 eth6 양방향 (디캡 뒤 안쪽 RoCE). 카운터: rxe hw_counters 전후
# 캡처는 nsx(함수) 대신 nsenter 로 바로 띄운다. 함수로 감싸면 $! 가 서브셸이라 kill 해도 tcpdump 가 남는다
# 결과: data/rxe-track.csv, data/rxe-counters.txt, data/pcap/rxe-*.pcap (앞 200개)
. "$(dirname "$0")/common.sh"
DUR=${1:-10}
OUT=$DATA/rxe-track.csv; CT=$DATA/rxe-counters.txt; mkdir -p "$DATA/pcap"
echo "tclass,gbps,spine_marked,spine_drops,outer_ce,inner_ce_to_e3,inner_ect0_to_e3,cnp_pkts,nak_pkts,ack_pkts,data_pkts" > "$OUT"
: > "$CT"
T() { docker exec rtool "$@"; }
hw() { for d in e1 e3; do for f in /sys/class/infiniband/rxe_$d/ports/1/hw_counters/*; do echo "$d $(basename $f) $(cat $f)"; done; done; }
red() { nsx spine1 tc -s -j qdisc show dev eth3 | python3 -c 'import json,sys; q=[q for q in json.load(sys.stdin) if q["kind"]=="red"][0]; print(q.get("marked",0), q.get("drops",0))'; }
n() { tcpdump -nn -r "$1" "$2" 2>/dev/null | grep -c '^[0-9]'; }   # VXLAN 은 두 줄로 찍히므로 시각 줄만

say "준비: rxe 서버 e1 (leaf1:eth6)·e3 (leaf3:eth6), setup.sh 다음에 실행"
for m in ib_core ib_uverbs rdma_ucm udp_tunnel ip6_udp_tunnel; do modprobe $m; done
lsmod | grep -q '^crc32_generic' || insmod /root/kbuild/crc32mod/crc32_generic.ko
lsmod | grep -q '^rdma_rxe' || insmod /root/kbuild/linux/drivers/infiniband/sw/rxe/rdma_rxe.ko
docker image inspect rdma-tools >/dev/null 2>&1 || docker build -q --network host -t rdma-tools "$EXP/../11-roce/tools"
docker ps --format '{{.Names}}' | grep -qx rtool || { docker rm -f rtool >/dev/null 2>&1
  docker run -d --name rtool --network host --privileged -v /dev/infiniband:/dev/infiniband -v /tmp:/tmp rdma-tools sleep infinity >/dev/null; }
ip rule show | grep -q '^32765:.*lookup local' || { ip rule add pref 32765 table local; ip rule del pref 0 table local; }
sysctl -qw net.ipv4.udp_l3mdev_accept=1 net.ipv4.tcp_l3mdev_accept=1
# ve1(VRF) 10.10.10.101/32 ← rxe 는 여기 (GID). e1(veth, VNI 안) 10.10.10.111/24. 상대 /32 는 상대 veth 주소를 다음 홉으로.
# VRF 장치 MTU 를 1500 으로 묶는다. rxe 는 붙은 장치(VRF, 기본 65536)의 MTU 로 RoCE MTU 를 정하는데,
# 그대로 두면 4096 이 되어 1500 짜리 VNI 를 못 지나간다 — 첫 시도에서 재전송이 끝없이 돌다 커널이 멈췄다 (soft lockup)
for n in 1 3; do
  o=$((4 - n)); L=leaf$n
  ip link show e$n >/dev/null 2>&1 && continue
  ip link add ve$n type vrf table 20$n; ip link set ve$n mtu 1500 up
  ip link add e$n type veth peer name eth6 netns "$(pid $L)"
  ip link set e$n master ve$n; ip link set e$n mtu 1500 up
  ip addr add 10.10.10.11$n/24 dev e$n
  ip addr add 10.10.10.10$n/32 dev ve$n
  ip route add 10.10.10.10$o/32 via 10.10.10.11$o dev e$n vrf ve$n
  nsx $L ip link set eth6 mtu 1500 master $BR up
  T rdma link add rxe_e$n type rxe netdev ve$n
done
sleep 2
T rdma link | grep rxe_e | sed 's/^/  /'
mtu=$(T ibv_devinfo -d rxe_e1 | awk '/active_mtu/{print $2}')
echo "rxe_e1 active_mtu: $mtu (VRF 장치 $(ip -o link show ve1 | grep -o 'mtu [0-9]*'))" | tee -a "$CT"
[ "$mtu" = 4096 ] && { echo "RoCE MTU 4096 — VNI(1500)를 못 지나간다. 중단"; exit 1; }
ping -I ve1 -c 2 -W 1 -q 10.10.10.103 2>/dev/null | tail -1 | sed 's/^/  ve1 → ve3 /'
for tc in 2 0; do
  W=$CAP/rxe-tc$tc; rm -rf "$W"; mkdir -p "$W"
  say "tclass $tc — e1 → e3 ib_write_bw 64KB × ${DUR}초"
  hw > "$W/hw0"; read m0 d0 < <(red)
  nsenter -t "$(pid leaf3)" -n tcpdump -i eth1 -Q in -s 128 -U -nn -w "$W/up.pcap" 'udp dst port 4789' >/dev/null 2>&1 & p1=$!
  nsenter -t "$(pid leaf3)" -n tcpdump -i eth6 -s 128 -U -nn -w "$W/host.pcap" 'udp port 4791' >/dev/null 2>&1 & p2=$!
  sleep 1
  T sh -c "timeout $((DUR + 15)) ib_write_bw -d rxe_e3 -x 1 -p 18610 -D $DUR -F -s 65536 --tclass=$tc > /tmp/e3srv.txt 2>&1" & sp=$!
  sleep 1
  bw=$(timeout -s KILL $((DUR + 15)) docker exec rtool ib_write_bw -d rxe_e1 -x 1 -p 18610 -D $DUR -F -s 65536 --tclass=$tc --report_gbits 127.0.0.1 2>&1 \
       | awk '/^ *65536/{print $4}')
  wait $sp; sleep 1; kill $p1 $p2; sleep 0.5
  hw > "$W/hw1"; read m1 d1 < <(red)
  # 안쪽 RoCE: UDP 4791 페이로드 0 바이트째 = BTH opcode. 0x81 CNP, 0x11 ACK(AETH 12바이트째 syndrome 상위 3비트 011 = NAK)
  cnp=$(n "$W/host.pcap" 'udp[8]=0x81')
  nak=$(n "$W/host.pcap" 'udp[8]=0x11 and udp[20]&0x60=0x60')
  ack=$(n "$W/host.pcap" 'udp[8]=0x11')
  dat=$(n "$W/host.pcap" 'dst host 10.10.10.103 and udp[8]!=0x11 and udp[8]!=0x81')
  echo "$tc,${bw:-fail},$((m1 - m0)),$((d1 - d0)),$(n "$W/up.pcap" 'ip[1]&3=3'),$(n "$W/host.pcap" 'dst host 10.10.10.103 and ip[1]&3=3'),$(n "$W/host.pcap" 'dst host 10.10.10.103 and ip[1]&3=2'),$cnp,$nak,$ack,$dat" >> "$OUT"
  { echo "== tclass $tc (변한 카운터만)"; join <(awk '{print $1"/"$2, $3}' "$W/hw0" | sort) <(awk '{print $1"/"$2, $3}' "$W/hw1" | sort) | awk '$3!=$2{print "  "$1, $3-$2}'; } >> "$CT"
  for p in up host; do tcpdump -r "$W/$p.pcap" -c 200 -w "$DATA/pcap/rxe-tc$tc-$p.pcap" 2>/dev/null; done
  echo "  ${bw:-실패} Gb/s, 스파인 마킹 $((m1 - m0)) 드랍 $((d1 - d0)), CNP $cnp, NAK $nak"
done
column -s, -t "$OUT"; cat "$CT"
