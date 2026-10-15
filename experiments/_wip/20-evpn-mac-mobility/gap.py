#!/usr/bin/env python3
"""ping -D -O 출력에서 끊긴 구간을 잰다.

  gap.py <ping.txt> [간격ms=10]
  → 'sent N recv M lost K longest_gap_ms G gaps [시작초:길이ms, ...]'
"""
import re, sys

fn = sys.argv[1]
iv = float(sys.argv[2]) if len(sys.argv) > 2 else 10
ok, seen = set(), set()
t_of = {}
for line in open(fn, errors="replace"):
    m = re.search(r"\[(\d+\.\d+)\].*icmp_seq=(\d+)", line)
    if not m:
        continue
    t, q = float(m.group(1)), int(m.group(2))
    seen.add(q); t_of.setdefault(q, t)
    if "bytes from" in line:
        ok.add(q)
if not seen:
    print("sent 0 recv 0 lost 0 longest_gap_ms 0 gaps []"); sys.exit()
hi = max(seen)
t0 = min(t_of.values())
gaps, run, start = [], 0, None
for q in range(1, hi + 1):
    if q in ok:
        if run:
            gaps.append((start, run))
        run, start = 0, None
    else:
        if run == 0:
            start = q
        run += 1
if run:
    gaps.append((start, run))
longest = max((g[1] for g in gaps), default=0)
desc = ", ".join(f"{(t_of.get(s, t0) - t0):.2f}s:{n * iv:.0f}ms" for s, n in gaps if n >= 2)
print(f"sent {hi} recv {len(ok)} lost {hi - len(ok)} longest_gap_ms {longest * iv:.0f} gaps [{desc}]")
