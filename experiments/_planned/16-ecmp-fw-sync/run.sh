#!/bin/bash
# 실험 16 — ECMP + 방화벽 두 대. ./run.sh [0..4|all]   all 이면 capture/run-output.txt 에도 남는다.
# 회차마다 h1 -> srv curl N개(출발포트만 다름)를 보내고, 흐름마다 "갈 때 FW / 올 때 FW / 성공 여부 / 시간"을 맞춰 본다.
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"; mkdir -p capture
d()  { docker exec "clab-fwecmp-$1" "${@:2}"; }
db() { docker exec -d "clab-fwecmp-$1" "${@:2}"; }
say(){ printf '\n=== %s ===\n' "$*"; }
ind(){ sed 's/^/    /'; }
N=${N:-100}

# ---- 손잡이 ----
# hash <leaf> <policy> [fields]   policy 0=L3, 1=L4(5-튜플), 3=골라 넣기(fields 비트: 0x01 출발IP 0x02 목적IP 0x10 출발포트 0x20 목적포트)
hash()  { d "$1" sysctl -qw net.ipv4.fib_multipath_hash_policy="$2"; [ -n "$3" ] && d "$1" sysctl -qw net.ipv4.fib_multipath_hash_fields="$3"; true; }
order() { if [ "$1" = rev ]; then d leafB ip route replace 10.15.1.0/24 nexthop via 10.15.22.2 nexthop via 10.15.21.2
          else                    d leafB ip route replace 10.15.1.0/24 nexthop via 10.15.21.2 nexthop via 10.15.22.2; fi; }
filter(){ for f in fw1 fw2; do d $f nft delete table inet fw 2>/dev/null; [ "$1" = on ] && d $f nft -f /lab/nft/fw.nft; done; true; }
obs()   { for f in fw1 fw2; do d $f nft delete table inet obs 2>/dev/null; d $f nft -f /lab/nft/obs.nft; done; }
sync_on()  { for f in fw1 fw2; do d $f pkill conntrackd; d $f rm -f /tmp/conntrackd.lock /tmp/conntrackd.ctl /tmp/conntrackd.log; db $f conntrackd -C /lab/conntrackd/$f.conf; done; sleep 2; }
sync_off() { for f in fw1 fw2; do d $f pkill conntrackd; done; true; }
show_cfg() { echo "  leafA: policy=$(d leafA sysctl -n net.ipv4.fib_multipath_hash_policy) fields=$(d leafA sysctl -n net.ipv4.fib_multipath_hash_fields)   leafB: policy=$(d leafB sysctl -n net.ipv4.fib_multipath_hash_policy) fields=$(d leafB sysctl -n net.ipv4.fib_multipath_hash_fields)   leafB 넥스트홉 순서: $(d leafB ip route show 10.15.1.0/24 | grep -o 'via [0-9.]*' | awk '{printf "%s ", $2}')"; }

# ---- 한 회차 ----
# round <이름> <BASE>  → capture/<이름>.tsv 와 요약 한 줄. SNAP=1 이면 도중에 양쪽 방명록을 찍는다.
round() {
  local name=$1 base=$2
  for f in fw1 fw2; do d $f nft flush set inet obs syn; d $f nft flush set inet obs synack; d $f conntrack -F >/dev/null 2>&1; done
  d h1 sh /lab/tools/flows.sh "$base" "$N" 20 > /tmp/r.txt &
  if [ "${SNAP:-0}" = 1 ]; then
    sleep 1.2
    for f in fw1 fw2; do echo "  [$f 방명록, 1.2초 시점] 전체 $(d $f conntrack -C)개, 그중 UNREPLIED $(d $f conntrack -L 2>/dev/null | grep -c UNREPLIED)개. 예:"
      d $f conntrack -L -p tcp 2>/dev/null | head -2 | sed -E 's/ src=10.15.2.10 dst=10.15.1.10 sport=80 dport=[0-9]+//; s/ mark=0 use=1//' | ind; done
  fi
  wait; sleep 0.5
  for f in fw1 fw2; do for s in syn synack; do
    d $f nft list set inet obs $s | sed -n '/elements/,/}/p' | grep -o '[0-9]\+' > /tmp/$f.$s; done; done
  awk -v name="$name" '
    FILENAME ~ /fw1.syn$/    { o[$1] = o[$1] "fw1"; next }
    FILENAME ~ /fw2.syn$/    { o[$1] = o[$1] "fw2"; next }
    FILENAME ~ /fw1.synack$/ { b[$1] = b[$1] "fw1"; next }
    FILENAME ~ /fw2.synack$/ { b[$1] = b[$1] "fw2"; next }
    {
      p=$1; out=(p in o)?o[p]:"-"; back=(p in b)?b[p]:"-"; ok=($2=="200")
      # SYN이 h1을 못 떠남(출발포트 bind 실패) — 망 문제가 아니라 셈에서 뺀다
      if (out=="-" && back=="-" && $3==0) { LE++; printf "%s\t-\t-\t-\t로컬오류\t%s\t%s\n", p, $3, $4 > ("capture/" name ".tsv"); next }
      # 경로: 대칭(같은 FW 왕복) / 비대칭(다른 FW) / 경로바뀜(재전송 때 SYN이나 SYN-ACK이 다른 FW로 감 — 같은 흐름이 두 FW를 다 지남)
      k=(out=="fw1fw2" || back=="fw1fw2") ? "경로바뀜" : (out==back ? "대칭" : "비대칭")
      slow1=($3>=0.9); slow2=(ok && $4-$3>=0.15)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", p, out, back, k, ok?"성공":"실패", $3, $4 > ("capture/" name ".tsv")
      n++; K[k]++; KF[k]+=!ok; F+=!ok; O[out]++; L1+=slow1; L2+=slow2
    }
    END {
      if (LE) printf "  (h1 로컬 오류 %d개 제외 — 출발포트 bind 실패로 SYN이 안 나감)\n", LE
      printf "  흐름 %d | 갈 때 fw1 %d·fw2 %d | 성공 %d·실패 %d (실패율 %d%%)\n", n, O["fw1"], O["fw2"], n-F, F, 100*F/n
      printf "  경로별 실패: 대칭 %d/%d, 비대칭 %d/%d", KF["대칭"], K["대칭"], KF["비대칭"], K["비대칭"]
      if (K["경로바뀜"]) printf ", 재전송 때 경로바뀜 %d/%d", KF["경로바뀜"], K["경로바뀜"]
      printf " | 늦은 성공: connect ≥0.9s %d개, 데이터 ≥0.15s 지연 %d개\n", L1, L2
    }' /tmp/fw1.syn /tmp/fw2.syn /tmp/fw1.synack /tmp/fw2.synack /tmp/r.txt
  sed -i '1i 출발포트\t갈때FW\t올때FW\t경로\t결과\tconnect초\ttotal초' "capture/$name.tsv"
}
sample() { echo "  같은 h1 -> srv:80, 출발포트만 다른 연속 12개:"; sort -n "capture/$1.tsv" | awk -F'\t' 'NR>1 && NR<=13 {printf "    %s  %s→%s  %s\n", $1, $2, $3, $5}'; }

servers_up() {
  d srv pkill -f http.server; db srv sh -c 'cd /tmp && exec python3 -m http.server 80 >/dev/null 2>&1'
  for i in $(seq 20); do d srv curl -s -m1 -o /dev/null http://127.0.0.1/ && break; sleep 0.3; done
}

p0() { say "Phase 0 — 기록 안 하는 경비실 (필터 없음, 관측만). 해시: 양쪽 리프 '출발IP+출발포트'만"
  sync_off; servers_up; obs; filter off; order norm; hash leafA 3 0x11; hash leafB 3 0x11; show_cfg
  round p0-nofilter 20000; }

p1() { say "Phase 1 — 같은 해시, 이제 FW가 방명록을 쓴다"
  filter on; hash leafA 3 0x11; hash leafB 3 0x11; order norm; show_cfg
  SNAP=1 round p1-srconly 21000; sample p1-srconly
  echo "  drop 카운터  fw1: $(d fw1 nft list chain inet fw forward | grep -o 'packets [0-9]*')   fw2: $(d fw2 nft list chain inet fw forward | grep -o 'packets [0-9]*')"; }

# 5-튜플 대칭 해시 = policy 3 + fields 0x37 (출발IP·목적IP·프로토콜·출발포트·목적포트). 커널이 주소·포트를 정렬해 넣어 왕복이 같은 값.
SYM=0x37

p2() { say "Phase 2 — 비대칭이 생기는 다른 원인들"
  filter on
  echo "--- 2a. 분류센터마다 해시 방식이 다름: leafA = 5-튜플, leafB = L3(주소만)"
  hash leafA 3 $SYM; hash leafB 0; order norm; show_cfg; round p2a-l4-vs-l3 22000
  echo "--- 2b. 해시 방식은 같고(둘 다 5-튜플 대칭) 넥스트홉 순서만 다름"
  hash leafA 3 $SYM; hash leafB 3 $SYM; order rev; show_cfg; round p2b-order-rev 23000
  order norm
  echo "--- 2c. 함정: 리눅스 기본 'L4 해시'(policy 1). 패킷에 이미 해시값(보낸 소켓의 무작위 txhash)이 붙어 있으면 헤더 대신 그걸 쓴다"
  hash leafA 1; hash leafB 1; show_cfg; round p2c-policy1 23500; }

p3() { say "Phase 3 — 해결 ① 대칭 해시: 두 리프 다 5-튜플(policy 3, fields $SYM), 넥스트홉 순서 같게"
  filter on; hash leafA 3 $SYM; hash leafB 3 $SYM; order norm; show_cfg; round p3-symmetric 24000
  echo "--- 3b. 대칭이긴 한 L3 해시 (주소만) — 실패는 없지만 분산은?"
  hash leafA 0; hash leafB 0; show_cfg; round p3b-l3 25000; }

p4() { say "Phase 4 — 해결 ② 방명록 동기화(conntrackd). 해시는 Phase 1의 비대칭 그대로"
  filter on; hash leafA 3 0x11; hash leafB 3 0x11; order norm; show_cfg
  sync_on; echo "  conntrackd: fw1 $(d fw1 pgrep -c conntrackd)개, fw2 $(d fw2 pgrep -c conntrackd)개 실행 중 (FTFW, DisableExternalCache on, 동기화 링크 10.15.99.0/24)"
  echo "--- 4a. 랩 그대로 (RTT 약 0.1ms)"
  SNAP=1 round p4a-sync-rtt0 26000
  for ms in 1 10; do
    echo "--- 4b. leafB -> srv 에 지연 ${ms}ms (RTT 약 ${ms}ms) — 동기화가 SYN-ACK보다 먼저 도착할까"
    d leafB tc qdisc replace dev eth3 root netem delay ${ms}ms
    round p4b-sync-rtt$ms $((26000 + ms * 100))
  done
  echo "--- 4d. 지연을 양쪽에 10ms씩 (leafB -> srv, leafA -> h1) — 두 번째 경주(SYN-ACK -> ACK)도 넉넉하게"
  d leafA tc qdisc replace dev eth1 root netem delay 10ms
  round p4d-sync-both10 26500
  d leafA tc qdisc del dev eth1 root 2>/dev/null; d leafB tc qdisc del dev eth3 root 2>/dev/null
  echo "  동기화 통계 (fw1):"; d fw1 conntrackd -C /lab/conntrackd/fw1.conf -s network 2>/dev/null | grep -E 'Bytes|lost' | sed 's/^[[:space:]]*//' | ind
  echo "--- 4c. 대조군: 같은 지연 10ms, 동기화 끔"
  sync_off; d leafB tc qdisc replace dev eth3 root netem delay 10ms
  round p4c-nosync-rtt10 27000
  d leafB tc qdisc del dev eth3 root 2>/dev/null; }

case ${1:-all} in
  all) { p0; p1; p2; p3; p4; } 2>&1 | tee capture/run-output.txt ;;
  *)   p$1 ;;
esac
