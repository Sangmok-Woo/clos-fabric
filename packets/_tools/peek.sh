#!/usr/bin/env bash
# 가볍게 캡처하고 요약 표만 본다. 윈도우 Git Bash 에서 실행.
#   peek.sh <주제> <노드:인터페이스>... [-t 초] [-f "BPF"] [-g "노드 명령"] [-n 줄수] [-s snaplen]
#   예: peek.sh vxlan leaf1:eth3 spine1:eth1 -g "h1 ping -c 5 172.16.13.10"
# 결과: packets/<날짜>/raw/<주제>.pcap, <주제>.points.txt
set -e
export MSYS_NO_PATHCONV=1   # WSL 로 넘기는 /mnt/c 경로를 Git Bash 가 바꾸지 못하게
HERE=$(cd "$(dirname "$0")" && pwd)   # packets/_tools
ROOT=$(dirname "$HERE")                # packets
T="/c/Program Files/Wireshark/tshark.exe"
M="/c/Program Files/Wireshark/mergecap.exe"
DUR=20 BPF="" GEN="" ROWS=50 SNAP=256

topic=$1; shift || true
pts=()
while [ $# -gt 0 ]; do
  case $1 in
    -t) DUR=$2; shift 2 ;;
    -f) BPF=$2; shift 2 ;;
    -g) GEN+=$2$'\n'; shift 2 ;;
    -n) ROWS=$2; shift 2 ;;
    -s) SNAP=$2; shift 2 ;;
    *)  pts+=("$1"); shift ;;
  esac
done
[ -n "$topic" ] && [ ${#pts[@]} -ge 1 ] || { sed -n 3,4p "$0"; exit 1; }
[ ${#pts[@]} -le 4 ] || { echo "지점은 4개까지"; exit 1; }
[ "$DUR" -le 30 ] || { echo "캡처는 30초까지"; exit 1; }

DAY=$ROOT/$(date +%F)
OUT=$DAY/raw
mkdir -p "$OUT"
rm -f "$OUT"/pt_*.pcap

# 캡처 (WSL). 따옴표가 바깥 셸에 먹히지 않게 스크립트를 stdin 으로 넘긴다
echo "캡처 ${DUR}초: ${pts[*]}"
wsl -d Ubuntu -u root -- bash -s -- "/mnt/c${OUT#/c}" "$DUR" "$BPF" "$GEN" "$SNAP" "${pts[@]}" <<'EOF'
out=$1 dur=$2 bpf=$3 gen=$4 snap=$5; shift 5
pid() { docker inspect -f '{{.State.Pid}}' "clab-clos-$1" 2>/dev/null; }
for p in "$@"; do   # 하나라도 틀리면 아무것도 안 뜬다
  n=${p%%:*} i=${p#*:}
  [ -n "$(pid "$n")" ] && nsenter -t "$(pid "$n")" -n ip link show "$i" >/dev/null 2>&1 || { echo "$p 없음"; exit 1; }
done
tmp=$(mktemp -d); pids=()
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
for p in "$@"; do
  n=${p%%:*} i=${p#*:}
  nsenter -t "$(pid "$n")" -n tcpdump -Z root -i "$i" -s "$snap" -U -nn -w "$tmp/pt_${n}_$i.pcap" ${bpf:+"$bpf"} >/dev/null 2>&1 &
  pids+=($!)
done
sleep 1   # tcpdump 가 붙을 시간
while IFS= read -r g; do   # -g 는 여러 번 줄 수 있다. 동시에 돈다
  [ -n "$g" ] || continue
  timeout "$dur" docker exec "clab-clos-${g%% *}" sh -c "${g#* }" >/dev/null 2>&1 &
  pids+=($!)
done <<< "$gen"
sleep "$dur"
kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; pids=()
cp "$tmp"/*.pcap "$out/"
EOF

# 요약 표 (윈도우 tshark). 지점별 pcap 에서 뽑아 시간순으로 합친다
rows=$(for f in "$OUT"/pt_*.pcap; do
  b=$(basename "$f" .pcap); b=${b#pt_}; p="${b%%_*}:${b#*_}"
  "$T" -r "$(cygpath -w "$f")" -d udp.port==4789,vxlan -T fields -E separator=/t -E occurrence=a -E aggregator=, \
    -e frame.time_epoch -e ip.src -e ip.dst -e ipv6.src -e ipv6.dst -e eth.src -e eth.dst \
    -e vxlan.vni -e _ws.col.Protocol -e frame.len 2>/dev/null | tr -d '\r' | sed "s|^|$p\t|"
done | sort -t$'\t' -k2,2n)

total=$(printf '%s\n' "$rows" | grep -c . || true)
echo
echo "| 지점 | 시간 | 바깥 src→dst | VXLAN | VNI | 안쪽 src→dst | 프로토콜 | 크기 |"
echo "|---|---|---|---|---|---|---|---|"
printf '%s\n' "$rows" | head -n "$ROWS" | awk -F'\t' '
  function pick(s, d, k,   a, b) { split(s, a, ","); split(d, b, ","); return (a[k] == "") ? "" : a[k] "→" b[k] }
  function addr(k) { r = pick($3, $4, k); if (r == "") r = pick($5, $6, k); if (r == "") r = pick($7, $8, k); return r }
  NR == 1 { t0 = $2 }
  $1 != "" {
    vx = ($9 != "")
    # 바깥이 IPv4 면 안쪽 IP 는 두 번째. 안쪽이 IP 가 아니면(ARP 등) 안쪽 MAC
    inner = ""
    if (vx) { inner = pick($3, $4, 2); if (inner == "") inner = pick($5, $6, 1); if (inner == "") inner = pick($7, $8, 2) }
    printf "| %s | %.6f | %s | %s | %s | %s | %s | %s |\n", $1, $2 - t0, addr(1), vx ? "O" : "-", vx ? $9 : "", inner, $10, $11
  }'
[ "$total" -gt "$ROWS" ] && echo "(외 $((total - ROWS))개, -n 으로 더 보기)"

# 지점별 파일을 <주제>.pcap 하나로
# tcpdump pcap 에는 인터페이스 이름이 없다. Wireshark 의 frame.interface_id 가 아래 순서다
k=0; for f in "$OUT"/pt_*.pcap; do b=$(basename "$f" .pcap); b=${b#pt_}; echo "  interface_id $k = ${b%%_*}:${b#*_}"; k=$((k + 1)); done | tee "$OUT/$topic.points.txt"
"$M" -I none -w "$(cygpath -w "$OUT/$topic.pcap")" $(for f in "$OUT"/pt_*.pcap; do cygpath -w "$f"; done) && rm -f "$OUT"/pt_*.pcap
echo
echo "저장: ${DAY#"$ROOT"/}/raw/$topic.pcap ($total 패킷)"
