#!/usr/bin/env bash
# 지금 걸려 있는 병목·장애 그대로 한 번 잰다. 바꾸는 것은 계수기(초기화)와 트래픽(+ dcqcn 트랙의 흉내 도구)뿐.
#   measure.sh <tcp|roce|dcqcn> <출력 디렉터리> [초=60]
#   tcp    g1·g2·g4 → g3 iperf3 DCTCP (트랙 B)
#   roce   같은 방향 rxe ib_write_bw 64KB, tclass 106 (DSCP 26 + ECT0) — rxe 그대로 (트랙 A, 반응 없음)
#   dcqcn  roce + 실험 13 의 흉내 DCQCN (g3 앞에서 안쪽 CE 를 보고 CNP, 송신측 htb 로 감속)
# 결과: sampler.csv(1초 계수기) + iperf3 JSON 또는 ib_write_bw 출력 (+ np.json·rp.json·rp-timeline.csv)
set -u
. "$(dirname "$0")/common.sh"
tr=$1; O=$2; DUR=${3:-60}
mkdir -p "$O"
counters_on
pids=()
if [ $tr = dcqcn ]; then
  for n in $SENDERS; do sender_queue $n; done
  python3 "$EXP/scripts/dcqcn.py" np "$O" & pids+=($!)
  python3 "$EXP/scripts/dcqcn.py" rp "$O" & pids+=($!)
fi
[ $tr = tcp ] && tcp_on
python3 "$EXP/scripts/sampler.py" "$O/sampler.csv" $((DUR + 4)) & sp=$!
sleep 1
case $tr in
  tcp) tcp_traffic $DUR "$O/iperf" ;;
  roce|dcqcn) roce_traffic $DUR "$O/bw" 106 ;;
esac
wait $sp
if [ ${#pids[@]} -gt 0 ]; then
  kill -TERM "${pids[@]}" 2>/dev/null
  for i in $(seq 50); do a=0; for p in "${pids[@]}"; do kill -0 $p 2>/dev/null && a=1; done; [ $a = 0 ] && break; sleep 0.1; done
  kill -9 "${pids[@]}" 2>/dev/null
  for n in $SENDERS; do tc qdisc del dev xg$n root 2>/dev/null; done
fi
# 한 줄 요약
python3 - "$O" "$tr" <<'PY'
import csv, glob, json, os, re, sys
o, tr = sys.argv[1], sys.argv[2]
r = list(csv.DictReader(open(f"{o}/sampler.csv")))
a, b = r[0], r[-1]
d = lambda k: int(b[k]) - int(a[k])
tot = (d("rx_g1_B") + d("rx_g2_B") + d("rx_g4_B")) * 8 / (float(b["t"]) - float(a["t"])) / 1e6
extra = ""
if tr == "tcp":
    rt = sum(sum(i["sum"]["retransmits"] for i in json.load(open(f))["intervals"]) for f in glob.glob(f"{o}/iperf-g*.json") if os.path.getsize(f))
    gp = [json.load(open(f))["end"]["sum_received"]["bits_per_second"] / 1e6 for f in sorted(glob.glob(f"{o}/iperf-g*.json")) if os.path.getsize(f)]
    extra = f"goodput {'+'.join(f'{x:.0f}' for x in gp)}={sum(gp):.0f}Mbit  retrans {rt}"
else:
    gp = []
    for f in sorted(glob.glob(f"{o}/bw-g*.txt")):
        m = [l.split() for l in open(f) if re.match(r"^\s*\d+\s+\d+\s", l)]
        gp.append(float(m[-1][3]) * 1000 if m else 0)
    extra = f"perftest {'+'.join(f'{x:.0f}' for x in gp)}={sum(gp):.0f}Mbit  NAK {d('nak_g3')}  retry {d('retry_g1')+d('retry_g2')+d('retry_g4')}"
    if tr == "dcqcn" and os.path.exists(f"{o}/rp.json"):
        extra += f"  CNP수신 {sum(v['cnp_rcvd'] for v in json.load(open(f'{o}/rp.json')).values())}"
print(f"  수신 {tot:.0f}Mbit  스파인 표시 {d('sp_mark')} 드랍 {d('sp_drop')}  리프병목 표시 {d('lf_mark')} 드랍 {d('lf_drop')}  "
      f"바깥CE {d('outer_ce')} 안쪽CE {d('in_ce')}  ECE {d('ece')} CNP {d('cnp')}  {extra}")
PY
