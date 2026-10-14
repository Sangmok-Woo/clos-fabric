#!/usr/bin/env python3
"""run.sh 의 state/ 를 읽어 Phase 별 성공률과 모니터링 알람 시각을 정리한다.
알람 시각은 Prometheus 에 ALERTS 시계열을 1초 간격으로 물어 처음 firing 이 된 때로 잡는다."""
import json, sys, urllib.parse, urllib.request

st = sys.argv[1]
tl = [l.split() for l in open(f"{st}/timeline")]
T = {k: float(v) for k, v in tl}
order = [k for k, _ in tl]
names = {"P0": "정상", "P1": "숨은 MTU 결함", "P2": "+ spine1 먹통", "P3": "spine1 복구", "P4": "MTU 복구"}

def load(f):
    return [(float(t), int(ok)) for t, ok in (l.split() for l in open(f"{st}/{f}"))]

http, ping = load("http"), load("ping")

def rate(samples, a, b):
    xs = [ok for t, ok in samples if a <= t < b]
    return f"{100 * sum(xs) / len(xs):.0f}% ({sum(xs)}/{len(xs)})" if xs else "-"

print("## Phase 별 성공률 (h1 → h3)\n")
print("| Phase | 길이 | HTTP 1MB | 작은 ping |")
print("|---|---|---|---|")
for a, b in zip(order, order[1:]):
    print(f"| {a} {names.get(a, '')} | {T[b] - T[a]:.0f}초 | {rate(http, T[a], T[b])} | {rate(ping, T[a], T[b])} |")

def q_range(expr, a, b):
    u = "http://localhost:9090/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": expr, "start": a, "end": b, "step": "1"})
    return json.load(urllib.request.urlopen(u))["data"]["result"]

a, b = T["P0"] - 5, T["END"] + 5
print("\n## 모니터링 알람 (처음 firing 이 된 시각, 기준은 그 알람을 만든 사건)\n")
print("| 알람 | 대상 | firing | 해제 | 사건 → firing |")
print("|---|---|---|---|---|")
rows = []
for r in q_range('ALERTS{alertstate="firing"}', a, b):
    m = r["metric"]
    ts = [float(t) for t, _ in r["values"]]
    who = m.get("link") or m.get("node") or ""
    rows.append((ts[0], m["alertname"], who, ts[-1]))
cause = {"FabricMTUMismatch": "P1", "LinkLargeFrameLoss": "P1", "InterfaceDropping": "P1",
         "RouterUnreachable": "P2", "BGPSessionsBelowExpected": "P2", "LinkProbeDown": "P2",
         "FabricRoutesDropped": "P2"}
for t0, name, who, t1 in sorted(rows):
    c = cause.get(name, "P1" if t0 < T["P2"] else "P2")
    print(f"| {name} | {who} | {c}+{t0 - T[c]:.0f}초 | {'END' if t1 >= T['END'] else f'+{t1 - T[c]:.0f}초'} | {t0 - T[c]:.1f}초 |")

# BGP 세션이 내려간 시각 (모니터링이 본 값, 5초 scrape)
r = q_range('sum(clos_bgp_peers_established{role="leaf"})', a, b)   # 리프 쪽 세션만 (스파인 자신의 값은 먹통이면 사라진다)
if r:
    vals = [(float(t), float(v)) for t, v in r[0]["values"]]
    low = [t for t, v in vals if t > T["P2"] and v < 8]
    back = [t for t, v in vals if t > T["P3"] and v >= 8]
    if low:
        mn = min(v for t, v in vals if T["P2"] < t < T["P3"])
        print(f"\n- 리프 쪽 세션 감소를 모니터링이 본 시각: P2+{low[0] - T['P2']:.0f}초 (8 → {mn:.0f})")
    if back:
        print(f"- 리프 쪽 세션 8 회복: P3+{back[0] - T['P3']:.0f}초")

# 링크 프로브가 spine1 먹통 동안 무엇을 봤나
r = q_range('min(clos_link_probe_success{link=~"spine1-.*"})', T["P2"] + 10, T["P3"])
if r:
    v = sorted(set(x for _, x in r[0]["values"]))
    print(f"- spine1 링크 프로브 최솟값 (P2 동안): {', '.join(v)}  (1 = ping 성공)")
