# 수렴 장(13·14)의 시간 계산 도구. 챕터 스크립트가 lab.sh 다음에 source 한다.
# 기준 시각 T0(장애 주입, epoch 초)에서 몇 초 뒤인지로 찍는다. 컨테이너는 WSL 커널 시계를 같이 쓰므로
# pcap 타임스탬프와 date +%s.%N 을 그대로 비교할 수 있다.

now() { date +%s.%N; }

# ping 응답이 끊긴 가장 긴 구간: reply_gap <pcap> <T0>  →  "끊김 X초 (T0+a ~ T0+b)"
reply_gap() {
  tcpdump -tt -nn -r "$1" 'icmp[icmptype]==icmp-echoreply' 2>/dev/null | awk -v t0="$2" '
    NR>1 { d=$1-p; if (d>m) { m=d; s=p; e=$1 } } { p=$1 }
    END { if (m) printf "응답 공백 %.2f초 (T0%+.2f ~ T0%+.2f)", m, s-t0, e-t0; else print "응답 없음" }'
}

# 보낸 요청 중 응답이 없는 것: lost <pcap>  (ICMP id/seq 짝으로 센다)
lost() {
  tcpdump -nn -r "$1" icmp 2>/dev/null | awk '
    /echo request/ { for(i=1;i<=NF;i++) if($i=="seq") q[$(i+1)]=1 }
    /echo reply/   { for(i=1;i<=NF;i++) if($i=="seq") delete q[$(i+1)] }
    END { n=0; for (k in q) n++; print n }'
}

# BGP·BFD 메시지를 T0 기준 시각으로: bgp_events <pcap> <T0> [from] [to]
#   from/to 는 T0 기준 초. 그 구간의 KEEPALIVE 는 빼고 나머지(OPEN·UPDATE·NOTIFICATION)만, BFD 는 상태가 바뀔 때만
bgp_events() {
  local f=$1 t0=$2 from=${3:--5} to=${4:-60}
  tcpdump -tt -nn -v -r "$f" 2>/dev/null | awk -v t0="$t0" -v from="$from" -v to="$to" '
    /^[0-9]+\.[0-9]+ / { ts=$1; hdr=$0; next }
    /^ +[0-9.]+ > [0-9.]+:/ { split($0,a," "); sd=a[1] " > " a[3]; sub(":$","",sd) }
    / Message \([0-9]+\)/ && !/Keepalive/ {
      r=ts-t0; if (r<from||r>to) next
      m=$0; sub(/^[ \t]+/,"",m); sub(/, length: [0-9]+/,"",m); printf "  T0%+7.3f  %-26s %s\n", r, sd, m }
    /BFDv1, length/ { getline; st=$0; sub(/.*State /,"",st); sub(/,.*/,"",st)
      dg=$0; sub(/.*Diagnostic: /,"",dg); sub(/ \(0x.*/,"",dg)
      r=ts-t0; key=sd
      if (r>=from && r<=to && last[key]!=st) printf "  T0%+7.3f  %-26s BFD State %s (%s)\n", r, sd, st, dg
      last[key]=st }'
}
