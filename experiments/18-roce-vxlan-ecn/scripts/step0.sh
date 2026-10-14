#!/usr/bin/env bash
# Step 0 — 환경 점검과 "rxe 가 DCQCN(CE→CNP→감속)을 하는가" 실측. 결과는 data/step0.txt
#  1) 커널·모듈·MTU·rxe 계수기 목록
#  2) rxe 소스에 CNP/ECN 처리가 있는가 (/root/kbuild 의 빌드 트리)
#  3) spine1:eth3 에 RED(ecn) 병목을 걸고 g1→g3 RoCE(tclass 106 = DSCP 26 + ECT0) 10초.
#     g3 앞(xg3)과 g1 앞(xg1)을 캡처해서 CE 가 g3 까지 왔는지, g3 가 CNP(BTH opcode 0x81)를 보냈는지 센다
set -u
. "$(dirname "$0")/common.sh"
OUT=$DATA/step0.txt
exec > >(tee "$OUT") 2>&1
mkdir -p "$CAPDIR"

say "1) 환경"
echo "  커널 $(uname -r)"
lsmod | grep -E '^(rdma_rxe|ib_core|ib_uverbs|crc32_generic|tcp_dctcp)' | awk '{print "  모듈 "$1}'
T rdma link | grep rxe_x | sed 's/^/  /'
echo "  MTU  xg1 $(cat /sys/class/net/xg1/mtu) / leaf1 eth6 $(dx leaf1 cat /sys/class/net/eth6/mtu) / leaf1 vni$VNI $(dx leaf1 cat /sys/class/net/vni$VNI/mtu) / 언더레이 leaf1 eth1 $(dx leaf1 cat /sys/class/net/eth1/mtu) spine1 eth3 $(dx spine1 cat /sys/class/net/eth3/mtu)"
echo "  RoCE active_mtu $(T ibv_devinfo -d rxe_x1 | awk '/active_mtu/{print $2, $3}')  (RoCE 4096 + BTH·UDP·IP·Eth ≈ 4170B < 9000, VXLAN 50B 더해도 < 9500)"
echo "  rxe hw_counters: $(ls /sys/class/infiniband/rxe_x1/ports/1/hw_counters | tr '\n' ' ')"
echo "  (실제 NIC mlx5 의 np_cnp_sent · rp_cnp_handled · np_ecn_marked_roce_packets 같은 혼잡 제어 계수기가 없다)"

say "2) rxe 소스 (drivers/infiniband/sw/rxe)"
SRC=/root/kbuild/linux/drivers/infiniband/sw/rxe
echo "  'cnp|ecn|congest' 를 쓰는 줄 (.c): $(grep -l -i -E 'cnp|ecn|congest' $SRC/*.c 2>/dev/null | wc -l)개 파일"
echo "  IB_OPCODE_CNP 를 쓰는 곳: $(grep -l 'IB_OPCODE_CNP\|OPCODE_CNP' $SRC/*.c $SRC/*.h 2>/dev/null | wc -l)개 파일"
echo "  FECN/BECN: rxe_hdr.h 에 비트 읽기·쓰기 함수만 있고 호출하는 곳 $(grep -l -E 'bth_(set_)?(fecn|becn)' $SRC/*.c 2>/dev/null | wc -l)개"
echo "  송신 IP TOS: rxe_net.c 가 tclass 를 그대로 iph->tos 에 → $(grep -n 'iph->tos' $SRC/rxe_net.c | head -1)"

say "3) 실측 — CE 를 받은 rxe 가 CNP 를 보내는가"
bneck_on spine1 eth3 roce
counters_on
P=$CAPDIR/step0-xg3.pcap; Q=$CAPDIR/step0-xg1.pcap
tcpdump -i xg3 -s 96 -U -nn -w $P udp port 4791 >/dev/null 2>&1 & c1=$!
tcpdump -i xg1 -s 96 -U -nn -w $Q udp port 4791 >/dev/null 2>&1 & c2=$!
sleep 1
python3 "$EXP/scripts/sampler.py" $DATA/step0-sampler.csv 12 & sp=$!
T sh -c "timeout 25 ib_write_bw -d rxe_x3 -x 1 -p 18601 -s 65536 -D 10 -F --tclass=106 > /tmp/s18-0.txt 2>&1" &
sleep 1.5
timeout 25 docker exec rtool ib_write_bw -d rxe_x1 -x 1 -p 18601 -s 65536 -D 10 -F --tclass=106 --report_gbits $OOB > $DATA/step0-bw.txt 2>&1
wait $sp; sleep 1; kill $c1 $c2; sleep 0.5
echo "  처리량 $(awk '/^ *[0-9]+ +[0-9]+ /{print $4" Gb/s"}' $DATA/step0-bw.txt)"
read d m b < <(nsx spine1 tc -s -j qdisc show dev eth3 | python3 -c 'import json,sys; q=[q for q in json.load(sys.stdin) if q.get("handle")=="10:"][0]; print(q["drops"], q.get("marked",0), q["backlog"])')
echo "  spine1:eth3 RED  표시(CE) $m  드랍 $d"
echo "  leaf3:eth1 바깥 CE 패킷 $(tail -1 $DATA/step0-sampler.csv | cut -d, -f3)   xg3 안쪽 CE 패킷 $(tail -1 $DATA/step0-sampler.csv | cut -d, -f4)"
echo "  xg3 캡처: g1→g3 RoCE $(tcpdump -nn -r $P 'src host 10.10.10.101' 2>/dev/null | wc -l), 그중 CE $(tcpdump -nn -r $P 'src host 10.10.10.101 and ip[1] & 3 = 3' 2>/dev/null | wc -l)"
echo "  xg3 캡처: g3→g1 전체 $(tcpdump -nn -r $P 'src host 10.10.10.103' 2>/dev/null | wc -l), 그중 BTH opcode 0x81(CNP) $(tcpdump -nn -r $P 'src host 10.10.10.103 and udp[8] = 0x81' 2>/dev/null | wc -l), ACK(0x11) $(tcpdump -nn -r $P 'src host 10.10.10.103 and udp[8] = 0x11' 2>/dev/null | wc -l)"
echo "  xg1 캡처: g1 이 받은 CNP $(tcpdump -nn -r $Q 'dst host 10.10.10.101 and udp[8] = 0x81' 2>/dev/null | wc -l)"
echo "  g3→g1 패킷의 BTH opcode 분포:"; tcpdump -nn -r $P -x 'src host 10.10.10.103' 2>/dev/null | awk '/0x0010:/{print "0x" substr($8,1,2)}' | sort | uniq -c | sed 's/^/     /'
echo "  rxe_x1 sent_pkts $(cnt 1 sent_pkts)  completer_retry_err $(cnt 1 completer_retry_err)   rxe_x3 rcvd_pkts $(cnt 3 rcvd_pkts) out_of_seq_request $(cnt 3 out_of_seq_request)"
bneck_off spine1 eth3
for f in $P $Q; do head_pcap $f 400; done
