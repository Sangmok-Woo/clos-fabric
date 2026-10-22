#!/usr/bin/env bash
# Step 1 — 리눅스 vxlan(리프 VTEP)이 ECN 을 옮겨 적는가 (Q1).
#  a) 캡슐화: g1 이 안쪽 TOS 를 바꿔 ping → leaf1:eth1(송신 리프 업링크)에서 바깥/안쪽 TOS
#  b) 디캡: spine1:eth3 egress 에서 바깥 ECN 을 강제로 00/01/10/11 → xg3(디캡 후)에서 안쪽 TOS, 도착 수
#  c) 실제 병목: spine1:eth3 RED(ecn) 에 TCP(DCTCP)·RoCE 5초 → 스파인 표시 / leaf3:eth1 바깥 CE / xg3 안쪽 CE
#  a~c 를 vxlan tos 옵션 0(기본)·inherit·0x68(고정) 으로 반복
set -u
. "$(dirname "$0")/common.sh"
exec > >(tee "$DATA/step1.txt") 2>&1
mkdir -p "$CAPDIR"
TMP=$(mktemp -d)
G1=$(ip_of 1); G3=$(ip_of 3)

cap() { nsenter -t "$(pid $1)" -n tcpdump -i $2 -s 128 -U -nn -w $3 ${@:4} >/dev/null 2>&1 & echo $!; }

say "a) 캡슐화 — 안쪽 ECN 이 바깥으로 복사되는가 (leaf1:eth1)"
echo "opt,inner_set,outer_tos,inner_tos,pkts" > $DATA/step1-encap.csv
for opt in 0 inherit 0x68; do
  vx_tos $opt
  echo "  -- vxlan tos $opt ($(dx leaf1 ip -d link show vni$VNI | grep -o 'tos [^ ]*' || echo 'tos 기본'))"
  for q in 0x00 0x01 0x02 0x03 0x6a 0x6b; do
    p=$(cap leaf1 eth1 $TMP/e.pcap udp port 4789); sleep 0.5
    ping -I vr1 -Q $q -c 5 -i 0.05 -W 1 -q $G3 >/dev/null 2>&1
    sleep 0.5; kill $p; sleep 0.3
    python3 "$EXP/scripts/tos.py" $TMP/e.pcap $G1 | while read o i n; do
      echo "     안쪽 $q 로 보냄 → $o $i  $n개"
      echo "$opt,$q,${o#outer=},${i#inner=},$n" >> $DATA/step1-encap.csv
    done
    [ "$opt" = 0 ] && [ "$q" = 0x6a ] && cp $TMP/e.pcap $CAPDIR/step1a-leaf1-eth1-tos0-inner0x6a.pcap
  done
done

say "b) 디캡 — 바깥 ECN 이 안쪽으로 옮겨지는가 (spine1:eth3 에서 바깥을 강제로 바꾸고 xg3 에서 본다)"
echo "opt,outer_forced,inner_sent,sent,arrived,inner_on_arrival" > $DATA/step1-decap.csv
nsx spine1 tc qdisc replace dev eth3 clsact
dm0=$(dmesg | grep -c 'non-ECT')
for opt in 0 inherit; do
  vx_tos $opt
  echo "  -- vxlan tos $opt"
  printf "     %-12s" "바깥\\안쪽"; for y in 0x00 0x01 0x02 0x03; do printf "%-18s" "$y"; done; echo
  for x in 0x00 0x01 0x02 0x03; do
    nsx spine1 tc filter del dev eth3 egress pref 60 2>/dev/null
    nsx spine1 tc filter add dev eth3 egress pref 60 protocol ip flower ip_proto udp dst_port 4789 \
      action pedit ex munge ip tos set $x retain 0x03 pipe action csum ip
    printf "     %-12s" "$x"
    for y in 0x00 0x01 0x02 0x03; do
      p=$(cap leaf3 eth1 $TMP/o.pcap udp port 4789); sleep 0.3
      p2=$(tcpdump -i xg3 -s 128 -U -nn -w $TMP/i.pcap icmp and src host $G1 >/dev/null 2>&1 & echo $!); sleep 0.5
      ping -I vr1 -Q $y -c 5 -i 0.05 -W 1 -q $G3 >/dev/null 2>&1
      sleep 0.5; kill $p $p2; sleep 0.3
      outer=$(python3 "$EXP/scripts/tos.py" $TMP/o.pcap $G1 | awk '{print $1}' | sort -u | tr '\n' ' ')
      arr=$(tcpdump -nn -r $TMP/i.pcap 2>/dev/null | wc -l)
      inner=$(python3 "$EXP/scripts/tos.py" $TMP/i.pcap $G1 | awk '{sub("inner=","",$2); print $2}' | sort -u | tr '\n' ' ')
      [ -z "$inner" ] && inner="(드랍)"
      printf "%-18s" "$arr/5 ${inner#inner=}"
      echo "$opt,$x,$y,5,$arr,${inner% }" >> $DATA/step1-decap.csv
      [ "$opt" = 0 ] && [ "$x" = 0x03 ] && [ "$y" = 0x02 ] && cp $TMP/o.pcap $CAPDIR/step1b-leaf3-eth1-outerCE.pcap && cp $TMP/i.pcap $CAPDIR/step1b-xg3-outerCE-innerECT0.pcap
    done
    echo "   (바깥 확인: $outer)"
  done
done
nsx spine1 tc filter del dev eth3 egress pref 60 2>/dev/null
nsx spine1 tc qdisc del dev eth3 clsact 2>/dev/null
echo "  커널 로그 'non-ECT' (바깥 CE + 안쪽 Not-ECT 를 버릴 때 vxlan 이 남긴다): $(( $(dmesg | grep -c 'non-ECT') - dm0 ))줄 새로"
dmesg | grep 'non-ECT' | tail -2 | sed 's/^/     /'

say "c) 실제 병목 — spine1:eth3 RED(ecn) 가 바깥에 찍은 CE 가 안쪽까지 가는가"
tcp_on
counters_on
echo "opt,traffic,sp_mark,sp_drop,outer_vx,outer_ce,in_ce,in_ect0,in_notect,leaf1_outer_ect0_sample,leaf1_sample" > $DATA/step1-traffic.csv
for opt in 0 inherit 0x68; do
  vx_tos $opt
  for tr in tcp roce; do
    bneck_on spine1 eth3 $tr; counters_on
    p=$(cap leaf1 eth1 $TMP/l1.pcap -c 2000 udp port 4789)
    p2=$(cap spine1 eth3 $TMP/s.pcap -c 3000 udp port 4789)
    p3=$(tcpdump -i xg3 -s 128 -U -nn -c 3000 -w $TMP/x.pcap src host $G1 >/dev/null 2>&1 & echo $!)
    sleep 1
    if [ $tr = tcp ]; then tcp_traffic 5 $TMP/t; else roce_traffic 5 $TMP/r 106; fi
    sleep 1; kill $p $p2 $p3 2>/dev/null; sleep 0.3
    python3 "$EXP/scripts/sampler.py" $TMP/c.csv 0 >/dev/null
    IFS=, read -r _ ovx oce ice iect0 iect1 inot _ < <(tail -1 $TMP/c.csv)
    read d m b < <(nsx spine1 tc -s -j qdisc show dev eth3 | python3 -c 'import json,sys; q=[q for q in json.load(sys.stdin) if q.get("handle")=="10:"][0]; print(q["drops"], q.get("marked",0), q["backlog"])')
    l1=$(python3 "$EXP/scripts/tos.py" $TMP/l1.pcap | awk '{n+=$3} /outer=0x..\(ECT\(0\)\)/{e+=$3} END{print e+0, n+0}')
    printf "  tos %-7s %-4s 스파인 표시 %6s 드랍 %5s │ leaf3:eth1 바깥 VXLAN %6s 중 CE %6s │ xg3 안쪽 CE %6s ECT0 %6s Not-ECT %5s │ leaf1 업링크 바깥 ECT0 %s\n" \
      $opt $tr $m $d $ovx $oce $ice $iect0 $inot "$(echo $l1 | awk '{print $1"/"$2}')"
    echo "$opt,$tr,$m,$d,$ovx,$oce,$ice,$iect0,$inot,$l1" | tr ' ' ',' >> $DATA/step1-traffic.csv
    if [ $opt = 0 ]; then
      cp $TMP/s.pcap $CAPDIR/step1c-$tr-spine1-eth3.pcap; cp $TMP/x.pcap $CAPDIR/step1c-$tr-xg3.pcap; cp $TMP/l1.pcap $CAPDIR/step1c-$tr-leaf1-eth1.pcap
      echo "     spine1:eth3 캡처 (바깥, 안쪽) TOS:"; python3 "$EXP/scripts/tos.py" $TMP/s.pcap | sed 's/^/       /'
      echo "     xg3 캡처 (디캡 후) TOS:";            python3 "$EXP/scripts/tos.py" $TMP/x.pcap | sed 's/^/       /'
    fi
  done
done
vx_tos 0
bneck_off spine1 eth3
for f in $CAPDIR/step1*.pcap; do head_pcap $f 1000; done
rm -rf $TMP
