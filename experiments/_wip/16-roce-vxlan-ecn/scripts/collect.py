#!/usr/bin/env python3
"""measure.sh 한 회차의 원본(samples.tsv, iperf-*.json, ping.txt)을 1초 시계열 CSV 와 요약 한 줄로 만든다.
사용: collect.py <작업폴더> <이름> <회차> <병목> <data폴더>"""
import csv, json, os, re, statistics, sys

work, name, rep, bn, data = sys.argv[1:6]
senders = ["v1", "x2", "x4"]

def kv(s):
    return {k: int(v) for k, v in (x.split("=") for x in s.split())}

def red_stats(js):
    for q in json.loads(js):
        if q.get("kind") == "red":
            return {"drops": q.get("drops", 0), "backlog": q.get("backlog", 0),
                    "marked": q.get("marked", 0), "early": q.get("early", 0),
                    "pdrop": q.get("pdrop", 0)}
    return {"drops": 0, "backlog": 0, "marked": 0, "early": 0, "pdrop": 0}

def filt_pkts(js):
    try:
        for f in json.loads(js):
            for a in f.get("options", {}).get("actions", []):
                if a.get("kind") == "pedit":
                    return a.get("stats", {}).get("packets", 0)
    except Exception:
        pass
    return 0

rows = []
with open(os.path.join(work, "samples.tsv")) as fh:
    for line in fh:
        p = line.rstrip("\n").split("\t")
        if len(p) < 5:
            continue
        rows.append({"t": float(p[0]), **red_stats(p[1]), "rx": kv(p[2]), "tx": kv(p[3]), "dec": filt_pkts(p[4])})

def txsum(r, k):
    return sum(r["tx"].get(f"{s}.{k}", 0) for s in senders)

# iperf3: 송신별 1초 처리량(Mbit/s)·재전송
thr, rtx = {}, {}
for s in senders:
    try:
        j = json.load(open(os.path.join(work, f"iperf-{s}.json")))
        # 처리량은 수신측(서버) 기준. 송신측 값은 앱이 소켓에 쓴 양이라 병목보다 크게 나올 수 있다
        srv = j.get("server_output_json", {}).get("intervals") or j["intervals"]
        thr[s] = [iv["sum"]["bits_per_second"] / 1e6 for iv in srv]
        rtx[s] = [iv["sum"].get("retransmits", 0) for iv in j["intervals"]]
    except Exception as e:
        print(f"  iperf {s} 읽기 실패: {e}")
        thr[s], rtx[s] = [], []
n = max((len(v) for v in thr.values()), default=0)

# ping: 1초 칸마다 평균 RTT
pings = []
for line in open(os.path.join(work, "ping.txt")):
    m = re.match(r"\[(\d+\.\d+)\].*time=([\d.]+)", line)
    if m:
        pings.append((float(m.group(1)), float(m.group(2))))
t0 = rows[0]["t"] if rows else 0
rtt_bins = {}
for ts, ms in pings:
    rtt_bins.setdefault(int(ts - t0), []).append(ms)

out = os.path.join(data, f"{name}-r{rep}.csv")
cols = ["sec", "thr_v1", "thr_x2", "thr_x4", "thr_sum", "retrans", "bn_marked", "bn_drops", "bn_backlog_B",
        "rx_ce", "rx_ect0", "tx_delivered_ce", "rtt_ms"]
with open(out, "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(cols)
    for i in range(n):
        a, b = (rows[i], rows[i + 1]) if i + 1 < len(rows) else (rows[-1], rows[-1])
        v = [thr[s][i] if i < len(thr[s]) else 0 for s in senders]
        rt = rtt_bins.get(i + 1, [])
        w.writerow([i + 1, *[round(x, 2) for x in v], round(sum(v), 2),
                    sum(rtx[s][i] if i < len(rtx[s]) else 0 for s in senders),
                    b["marked"] - a["marked"], b["drops"] - a["drops"], b["backlog"],
                    b["rx"].get("InCEPkts", 0) - a["rx"].get("InCEPkts", 0),
                    b["rx"].get("InECT0Pkts", 0) - a["rx"].get("InECT0Pkts", 0),
                    txsum(b, "TCPDeliveredCE") - txsum(a, "TCPDeliveredCE"),
                    round(statistics.mean(rt), 3) if rt else ""])

f, l = rows[0], rows[-1]
allrtt = [ms for _, ms in pings]
summ = {
    "name": name, "rep": rep, "bottleneck": bn, "secs": n,
    "thr_mbps": round(sum(sum(thr[s]) for s in senders) / n, 1) if n else 0,
    "thr_min_sender": round(min(statistics.mean(thr[s]) for s in senders if thr[s]), 1) if n else 0,
    "retrans": sum(sum(rtx[s]) for s in senders),
    "bn_marked": l["marked"] - f["marked"], "bn_drops": l["drops"] - f["drops"],
    "rx_ce": l["rx"].get("InCEPkts", 0) - f["rx"].get("InCEPkts", 0),
    "rx_ect0": l["rx"].get("InECT0Pkts", 0) - f["rx"].get("InECT0Pkts", 0),
    "rx_noect": l["rx"].get("InNoECTPkts", 0) - f["rx"].get("InNoECTPkts", 0),
    "tx_delivered_ce": txsum(l, "TCPDeliveredCE") - txsum(f, "TCPDeliveredCE"),
    "tx_retrans_segs": txsum(l, "RetransSegs") - txsum(f, "RetransSegs"),
    "decap_filter_hits": l["dec"] - f["dec"],
    "rtt_avg_ms": round(statistics.mean(allrtt), 2) if allrtt else "",
    "rtt_p99_ms": round(sorted(allrtt)[int(len(allrtt) * 0.99) - 1], 2) if allrtt else "",
    "ping_loss": sum(1 for line in open(os.path.join(work, "ping.txt")) if "no answer" in line),
}
sp = os.path.join(data, "summary.csv")
new = not os.path.exists(sp)
with open(sp, "a", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(summ))
    if new:
        w.writeheader()
    w.writerow(summ)
print("  " + "  ".join(f"{k}={v}" for k, v in summ.items() if k not in ("name", "rep", "bottleneck")))
