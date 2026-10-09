#!/usr/bin/env python3
"""시나리오 한 개의 결과 파일(capture/<id>/)을 읽어 run-output 에 넣을 몇 줄로 줄인다.
  summary.py <시나리오 디렉터리>
"""
import csv, json, os, sys

d = sys.argv[1]

def load(name):
    p = os.path.join(d, name)
    return json.load(open(p)) if os.path.exists(p) else None

# 병목 큐 깊이 (20ms 마다 잰 backlog). 처음 0 이 아닌 값부터 = 인캐스트가 시작된 뒤
qp = os.path.join(d, "qdepth.jsonl")
if os.path.exists(qp):
    depth = []
    for chunk in open(qp).read().split("\n\n"):
        try:
            depth.append(next(q for q in json.loads(chunk) if q.get("handle") == "10:").get("backlog", 0))
        except (ValueError, StopIteration):
            pass
    start = next((i for i, b in enumerate(depth) if b > 0), len(depth))
    depth = sorted(depth[start:])
    if depth:
        pick = lambda f: depth[min(len(depth) - 1, int(len(depth) * f))]
        ms = lambda b: b * 8 / 300e6 * 1000      # 300Mbit 포트에서 그 큐를 비우는 데 걸리는 시간
        print(f"  병목 큐 깊이  중앙값 {pick(0.5) // 1024:5d}KB ({ms(pick(0.5)):5.1f}ms)   "
              f"95% {pick(0.95) // 1024:5d}KB ({ms(pick(0.95)):5.1f}ms)   최대 {depth[-1] // 1024:5d}KB   표본 {len(depth)}")

for v in ("v1", "v2"):
    try:
        s = load(f"{v}.json")["end"]["sum"]
        got = s["bits_per_second"] / 1e6 * (1 - s["lost_percent"] / 100)
        print(f"  피해자 {v.upper()}    받은 {got:5.1f} Mbit / 보낸 50   손실 {s['lost_percent']:.1f}%   지터 {s['jitter_ms']:.2f}ms")
    except Exception as e:
        print(f"  피해자 {v.upper()}    측정 실패 ({e})")

np_, rp = load("np.json"), load("rp.json")
if np_ and rp:
    # 트래픽이 흐른 구간(처음 CNP 이후)의 송신 속도 평균
    rows = list(csv.DictReader(open(os.path.join(d, "rp-timeline.csv"))))
    for g in ("g1", "g2", "g4"):
        mine = [r for r in rows if r["sender"] == g]
        first = next((float(r["ms"]) for r in mine if r["event"] != "tick"), None)
        ticks = [float(r["rate_mbit"]) for r in mine if r["event"] == "tick" and first is not None and float(r["ms"]) >= first]
        avg = sum(ticks) / len(ticks) if ticks else 0
        print(f"  DCQCN {g}    CE 받음 {np_[g]['ce_pkts']:6d} → CNP {np_[g]['cnp_sent']:4d} → 실제로 깎음 {rp[g]['cuts']:4d}회   "
              f"정한 속도 평균 {avg:5.0f}  최저 {rp[g]['min_rate_mbit']:4.0f} Mbit")

pfc = load("pfc.json")
if pfc:
    w, p = pfc["watch"], pfc["paused"]
    print(f"  PFC XOFF    leaf3:eth5 {w['leaf3:eth5']['xoff']}회 (큐 최고 {w['leaf3:eth5']['peak_backlog'] // 1024}KB)")
    for name, pre in (("1홉 스파인 → leaf3", "spine"), ("2홉 리프 업링크", "leaf"), ("3홉 서버 g", "g"), ("3홉 서버 h", "h")):
        sel = {k: v for k, v in p.items() if k.startswith(pre)}
        n = sum(v["pauses"] for v in sel.values())
        top = max(sel.items(), key=lambda kv: kv[1]["paused_ms"]) if sel else ("-", {"paused_ms": 0})
        print(f"  PFC 멈춤     {name:<16} {n:5d}회   가장 오래 멈춘 곳 {top[0]:<12} {top[1]['paused_ms']:7.0f}ms")
