#!/usr/bin/env python3
"""캡처를 1ms 단위로 다시 세서, 모니터링(5초 평균)에 묻힌 순간 속도를 그린다.
제공(leaf3:eth1+eth2, 스파인에서 들어온 것)과 도착(h3:eth1)을 Phase 별로 같은 길이 창에서 비교한다.
출력: img/io-1ms.svg, 표준출력에 Phase 별 수치."""
import subprocess, sys, os

capdir, tlf, imgdir = sys.argv[1:4]
T = {k: float(v) for k, v in (l.split() for l in open(tlf))}
LINK = 100  # Mbit/s

def frames(pcap):
    out = subprocess.run(["tcpdump", "-tt", "-nn", "-e", "-r", pcap], capture_output=True, text=True).stdout
    for line in out.splitlines():
        try:
            t = float(line.split()[0]); n = int(line.split("length ")[1].split(":")[0])
            yield t, n
        except Exception:
            pass

offered = sorted(list(frames(f"{capdir}/leaf3-eth1.pcap")) + list(frames(f"{capdir}/leaf3-eth2.pcap")))
arrived = sorted(frames(f"{capdir}/h3-eth1.pcap"))

def bins(fr, a, b, w=0.001):
    n = int((b - a) / w); out = [0] * n
    for t, sz in fr:
        k = int((t - a) / w)
        if 0 <= k < n:
            out[k] += sz
    return [x * 8 / w / 1e6 for x in out]   # Mbit/s

def avg(fr, a, b):
    return sum(sz for t, sz in fr if a <= t < b) * 8 / (b - a) / 1e6

WIN = 0.3
rows = []
for ph in ("smooth", "burst"):
    a, e = T[ph], T[ph + "-end"]
    s = a + 3                      # 시작 직후는 빼고 3초째부터 300ms
    o, r = bins(offered, s, s + WIN), bins(arrived, s, s + WIN)
    rows.append((ph, o, r, avg(offered, a, e), avg(arrived, a, e)))
    print(f"  {ph:6s}: 평균 제공 {avg(offered,a,e):5.1f} / 도착 {avg(arrived,a,e):5.1f} Mbit/s · "
          f"1ms 최대 제공 {max(bins(offered,a,e)):6.0f} Mbit/s, 1ms 중 링크(100) 넘은 칸 {sum(1 for x in bins(offered,a,e) if x>LINK)}개 / {int((e-a)*1000)}개")

# ── SVG: Phase 두 줄, 1ms 막대(제공=회색, 도착=파랑), 링크 100 선, 전체 평균 점선
W, H, PAD, ROWH = 900, 470, 60, 190
peak = max(max(o) for _, o, _, _, _ in rows)
ymax = 400   # 링크(100)와 평균선이 보이도록 위를 자른다. 잘린 막대는 꼭대기에 빨간 점
def y(v, top): return top + ROWH - min(v, ymax) / ymax * (ROWH - 30)
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="-apple-system,Segoe UI,Noto Sans KR,sans-serif" font-size="12">',
       f'<rect width="{W}" height="{H}" rx="10" fill="#ffffff"/>']
names = {"smooth": "고르게 보낼 때 (-b 30M)", "burst": "몰아서 보낼 때 (-b 30M/300)"}
for i, (ph, o, r, ao, ar) in enumerate(rows):
    top = 20 + i * (ROWH + 30); bw = (W - PAD - 20) / len(o)
    svg.append(f'<text x="{PAD}" y="{top+12}" font-weight="600" fill="#1f2937">{names[ph]} — 300ms 구간, 1ms 막대</text>')
    for k, (vo, vr) in enumerate(zip(o, r)):
        x = PAD + k * bw
        svg.append(f'<rect x="{x:.1f}" y="{y(vo,top):.1f}" width="{max(bw-0.3,0.5):.1f}" height="{top+ROWH-y(vo,top):.1f}" fill="#cbd5e1"/>')
        svg.append(f'<rect x="{x:.1f}" y="{y(vr,top):.1f}" width="{max(bw-0.3,0.5):.1f}" height="{top+ROWH-y(vr,top):.1f}" fill="#2563eb" opacity="0.85"/>')
        if vo > ymax:
            svg.append(f'<circle cx="{x+bw/2:.1f}" cy="{y(ymax,top)-3:.1f}" r="2" fill="#dc2626"/>')
    lines = [(LINK, f"링크 {LINK}", "#dc2626", "", W - 22, "end", -4),
             (ao, f"보낸 평균 {ao:.0f}", "#16a34a", ' stroke-dasharray="6 4"', PAD + 4, "start", -4),
             (ar, f"도착 평균 {ar:.0f}", "#1d4ed8", ' stroke-dasharray="2 3"', PAD + 4, "start", 14)]
    for v, txt, col, dash, tx, anc, dy in lines:
        svg.append(f'<line x1="{PAD}" x2="{W-20}" y1="{y(v,top):.1f}" y2="{y(v,top):.1f}" stroke="{col}" stroke-width="1.5"{dash}/>')
        svg.append(f'<text x="{tx}" y="{y(v,top)+dy:.1f}" text-anchor="{anc}" fill="{col}" font-weight="600">{txt}</text>')
    for v in (0, ymax // 2, ymax):
        svg.append(f'<text x="{PAD-6}" y="{y(v,top)+4:.1f}" text-anchor="end" fill="#6b7280">{int(v)}</text>')
svg.append(f'<text x="{PAD}" y="{H-12}" fill="#6b7280">회색: 스파인에서 들어온 양(leaf3:eth1+eth2) · 파랑: h3에 도착한 양 · 단위 Mbit/s · 빨간 점은 {int(ymax)}을 넘어 잘린 막대 (최대 {peak:.0f})</text>')
svg.append('</svg>')
os.makedirs(imgdir, exist_ok=True)
open(f"{imgdir}/io-1ms.svg", "w", encoding="utf-8").write("\n".join(svg))
print(f"  그림: img/io-1ms.svg")
