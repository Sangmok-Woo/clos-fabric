#!/usr/bin/env python3
"""spine1:eth3 RED(10:) 의 xstats 를 일정 간격으로 CSV 에.  redpoll.py <spine1 pid> <초> [간격=0.2]"""
import json, subprocess, sys, time
pid, dur = sys.argv[1], float(sys.argv[2])
iv = float(sys.argv[3]) if len(sys.argv) > 3 else 0.2
print("t,backlog,drops,marked,early,pdrop,other", flush=True)
t0 = time.monotonic()
while time.monotonic() - t0 < dur:
    out = subprocess.run(["nsenter", "-t", pid, "-n", "tc", "-s", "-j", "qdisc", "show", "dev", "eth3"], capture_output=True, text=True).stdout
    q = next((x for x in json.loads(out or "[]") if x.get("handle") == "10:"), {})
    print(f"{time.monotonic() - t0:.2f},{q.get('backlog', 0)},{q.get('drops', 0)},{q.get('marked', 0)},{q.get('early', 0)},{q.get('pdrop', 0)},{q.get('other', 0)}", flush=True)
    time.sleep(iv)
