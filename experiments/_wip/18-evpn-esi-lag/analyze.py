#!/usr/bin/env python3
# 회차 하나 정리: analyze.py <회차폴더> <시나리오> <회차>
#   times(T0 T1), to_mh.tx/rx, to_rm.tx/rx, ping-*.txt, events.txt 를 읽어
#   방향별 손실(장애 구간 [T0,T1) / 복구 구간 [T1,끝))과 사건 타임라인을 출력하고 ../results.csv 에 한 줄씩 붙인다.
import os, re, sys
from collections import defaultdict

d, scn, rep = sys.argv[1], sys.argv[2], sys.argv[3]
T0, T1 = map(float, open(f"{d}/times").read().split())
IV = 0.01

def runs(ts):
    """정렬된 손실 시각들 → 가장 긴 연속 손실(개수)"""
    best = cur = 0; prev = None
    for t in ts:
        cur = cur + 1 if prev is not None and t - prev < IV * 1.5 else 1
        best = max(best, cur); prev = t
    return best

def win(ts):
    f = [t for t in ts if T0 <= t < T1]; r = [t for t in ts if t >= T1]
    return f, r

def udp(name):
    t0, cnt, n = open(f"{d}/{name}.tx").read().split()
    t0, cnt, n = float(t0), int(cnt), int(n)
    got = defaultdict(set); late = 0
    for line in open(f"{d}/{name}.rx"):
        i, s, ts = line.split(); got[int(i)].add(int(s))
        if float(ts) - (t0 + int(s) * IV) > 0.1: late += 1   # 보내는 쪽이 100ms 넘게 밀림 = WSL 이 잠깐 멈춤
    if late: print(f"  ※ {name}: 보내는 쪽이 100ms 넘게 늦게 보낸 패킷 {late}개 (손실 아님, WSL 멈춤)")
    out = {"f": [0, 0, 0], "r": [0, 0, 0]}   # 손실 합, 최장 연속(개), 손실 본 흐름 수
    for i in range(n):
        lost = [t0 + s * IV for s in range(cnt) if s not in got[i]]
        for k, w in zip("fr", win(lost)):
            out[k][0] += len(w); out[k][1] = max(out[k][1], runs(w)); out[k][2] += 1 if w else 0
    return out, n

def ping(name):
    p = f"{d}/{name}.txt"
    if not os.path.exists(p): return None
    seen, ok = {}, set()
    for line in open(p):
        m = re.match(r"\[(\d+\.\d+)\] (.*)icmp_seq=(\d+)", line)
        if not m: continue
        ts, body, s = float(m[1]), m[2], int(m[3])
        if body.startswith("no answer"): seen.setdefault(s, ts - IV)
        else: ok.add(s); seen.setdefault(s, ts)
    lost = sorted(t for s, t in seen.items() if s not in ok)
    f, r = win(lost)
    return len(f), runs(f), len(r), runs(r)

rows = []
print(f"  {'방향':<22} {'장애 중 손실':>10} {'최장 끊김':>10} {'흐름':>6} │ {'복구 때 손실':>10} {'최장 끊김':>10} {'흐름':>6}")
for name, label in (("to_mh", "원격 → hmh (UDP)"), ("to_rm", "hmh → 원격 (UDP)")):
    o, n = udp(name)
    print(f"  {label:<22} {o['f'][0]:>10} {o['f'][1]*10:>8}ms {o['f'][2]:>4}/{n} │ {o['r'][0]:>10} {o['r'][1]*10:>8}ms {o['r'][2]:>4}/{n}")
    rows.append([scn, rep, name, o['f'][0], o['f'][1] * 10, o['f'][2], o['r'][0], o['r'][1] * 10, o['r'][2], n])
for name, label in (("ping-rm2mh", "ping 원격 → hmh"), ("ping-mh2rm", "ping hmh → 원격")):
    p = ping(name)
    if p is None: continue
    print(f"  {label:<22} {p[0]:>10} {p[1]*10:>8}ms {'':>6} │ {p[2]:>10} {p[3]*10:>8}ms")
    rows.append([scn, rep, name, p[0], p[1] * 10, "", p[2], p[3] * 10, "", 1])

ev = f"{d}/events.txt"
if os.path.exists(ev):
    print("  사건 (T0 = 장애, T1 = 복구 기준 초):")
    for line in open(ev):
        t, s = line.split(" ", 1); t = float(t)
        rel = f"T0{t-T0:+7.2f}" if t < T1 else f"T1{t-T1:+7.2f}"
        print(f"    {rel}  {s.rstrip()}")

csv = os.path.join(os.path.dirname(d.rstrip("/")), "results.csv")
new = not os.path.exists(csv)
with open(csv, "a") as f:
    if new: f.write("scenario,rep,dir,fault_lost,fault_maxgap_ms,fault_flows,rec_lost,rec_maxgap_ms,rec_flows,nflows\n")
    for r in rows: f.write(",".join(map(str, r)) + "\n")
