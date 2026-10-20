#!/usr/bin/env python3
# 캡처 네 곳(hmh:eth1·eth2, leaf3:eth1·eth2)을 합쳐 탐침 패킷이 어느 길로 다녔는지 본다.
#   pcapflow.py flows    <폴더>                       흐름마다 지난 길 (정상 상태 ECMP 확인)
#   pcapflow.py timeline <폴더> <T0> <T1> <제목> <out.svg>   100ms 칸마다 길별 패킷 수 → 그림 + 글 요약
# 폴더에는 hmh-eth1.pcap hmh-eth2.pcap leaf3-eth1.pcap leaf3-eth2.pcap 가 있어야 한다.
# 탐침: 원격→hmh = UDP 7001 (출발 40000+흐름), hmh→원격 = UDP 7002 (출발 41000+흐름). probe.py 참고
import struct, sys
from collections import defaultdict

VT = {"10.255.1.1": "leaf1", "10.255.1.2": "leaf2", "10.255.1.3": "leaf3"}
SP = {"leaf3-eth1": "spine1", "leaf3-eth2": "spine2"}
LEG = {"hmh-eth1": "leaf1", "hmh-eth2": "leaf2"}

def ip4(b): return ".".join(map(str, b))

def pcap(path):
    with open(path, "rb") as f:
        hdr = f.read(24)
        if len(hdr) < 24: return
        e = "<" if hdr[:4] == b"\xd4\xc3\xb2\xa1" else ">"
        while True:
            h = f.read(16)
            if len(h) < 16: return
            s, us, cl, _ = struct.unpack(e + "IIII", h)
            yield s + us / 1e6, f.read(cl)

def l3(p):
    """이더넷 프레임 → (출발IP, 목적IP, 프로토, 출발포트, 목적포트, 나머지) 또는 이더타입"""
    et = struct.unpack("!H", p[12:14])[0]
    if et != 0x0800: return et
    ihl = (p[14] & 15) * 4; ip = p[14:]
    src, dst, pr = ip4(ip[12:16]), ip4(ip[16:20]), ip[9]
    sp = dp = 0
    if pr in (6, 17) and len(ip) >= ihl + 4: sp, dp = struct.unpack("!HH", ip[ihl:ihl + 4])
    return src, dst, pr, sp, dp, ip[ihl:]

def probe(x):
    """탐침이면 (방향, 흐름)"""
    if not isinstance(x, tuple) or x[2] != 17: return None
    if x[4] == 7001 and 40000 <= x[3] < 40100: return "to_mh", x[3] - 40000
    if x[4] == 7002 and 41000 <= x[3] < 41100: return "to_rm", x[3] - 41000
    return None

def read(d):
    """→ [(시각, 길, 방향, 흐름)], [(시각, 사건)]"""
    pk, ev = [], []
    for cap in ("hmh-eth1", "hmh-eth2", "leaf3-eth1", "leaf3-eth2"):
        try: it = list(pcap(f"{d}/{cap}.pcap"))
        except FileNotFoundError: continue
        for t, p in it:
            if len(p) < 14: continue
            x = l3(p)
            if x == 0x8809: ev.append((t, f"LACP {LEG.get(cap, cap)}")); continue
            if not isinstance(x, tuple): continue
            if cap.startswith("hmh"):
                pr = probe(x)
                if pr:
                    arrow = f"{LEG[cap]}→hmh" if pr[0] == "to_mh" else f"hmh→{LEG[cap]}"
                    pk.append((t, arrow, *pr))
                continue
            # leaf3 가 받는 UPDATE 만 (링크 /31 에서 스파인 쪽이 짝수 주소)
            if x[2] == 6 and 179 in (x[3], x[4]) and int(x[0].split(".")[3]) % 2 == 0 and len(x[5]) > 20 + 18:
                off = (x[5][12] >> 4) * 4; body = x[5][off:]
                while len(body) >= 19:   # 한 세그먼트에 BGP 메시지 여러 개
                    ln, ty = struct.unpack("!H", body[16:18])[0], body[18]
                    if ty == 2: ev.append((t, f"BGP UPDATE {SP[cap]}→leaf3"))
                    if ln < 19: break
                    body = body[ln:]
                continue
            if x[2] == 17 and x[4] == 4789 and len(x[5]) >= 8 + 8 + 14:
                inner = l3(x[5][16:])
                pr = probe(inner)
                if not pr: continue
                if pr[0] == "to_mh": arrow = f"leaf3→{SP[cap]}→{VT.get(x[1], x[1])}"
                else: arrow = f"{VT.get(x[0], x[0])}→{SP[cap]}→leaf3"
                pk.append((t, arrow, *pr))
    return pk, ev

LANES = {
    "to_mh": ["leaf3→spine1→leaf1", "leaf3→spine2→leaf1", "leaf3→spine1→leaf2", "leaf3→spine2→leaf2", "leaf1→hmh", "leaf2→hmh"],
    "to_rm": ["hmh→leaf1", "hmh→leaf2", "leaf1→spine1→leaf3", "leaf1→spine2→leaf3", "leaf2→spine1→leaf3", "leaf2→spine2→leaf3"],
}
TITLE = {"to_mh": "원격(hrem) → hmh", "to_rm": "hmh → 원격(hrem)"}

def flows(d):
    pk, _ = read(d)
    seen = defaultdict(lambda: defaultdict(int))
    for t, lane, dr, fl in pk: seen[(dr, fl)][lane] += 1
    for dr in ("to_mh", "to_rm"):
        print(f"  {TITLE[dr]}")
        for k in sorted(k for k in seen if k[0] == dr):
            ls = seen[k]; tot = max(ls.values())
            path = "  ".join(f"{l}({ls[l]})" for l in LANES[dr] if ls.get(l))
            print(f"    흐름 {k[1]}: {path}")

def timeline(d, T0, T1, title, out):
    pk, ev = read(d)
    B = 0.1
    wins = [("장애 T0", T0, -1.0, 6.0), ("복구 T1", T1, -1.0, 9.0)]
    cnt = defaultdict(int)
    for t, lane, dr, fl in pk:
        for wi, (_, base, a, b) in enumerate(wins):
            if base + a <= t < base + b: cnt[(wi, dr, lane, int((t - base - a) / B))] += 1
    # 글 요약: 0.5초 칸
    for wi, (nm, base, a, b) in enumerate(wins):
        print(f"  [{nm} 기준 0.5초 칸, 칸당 기대 {int(0.5/0.01*4)}개(흐름 4개)]")
        nb = int((b - a) / 0.5)
        print("    " + " " * 22 + "".join(f"{a + i*0.5:>+6.1f}" for i in range(nb)))
        for dr in ("to_mh", "to_rm"):
            for lane in LANES[dr]:
                row = [sum(cnt.get((wi, dr, lane, j), 0) for j in range(i * 5, i * 5 + 5)) for i in range(nb)]
                if sum(row): print(f"    {lane:<22}" + "".join(f"{v:>6}" for v in row))
    # 그림
    LW, CW, RH, GAP = 170, 6, 16, 26
    ncol = [int((b - a) / B) for _, _, a, b in wins]
    W = LW + sum(ncol) * CW + 40 + 20
    rows = []
    for dr in ("to_mh", "to_rm"): rows += [("h", TITLE[dr])] + [("l", dr, l) for l in LANES[dr]]
    rows += [("h", "제어 신호 (BGP UPDATE @leaf3, LACP @hmh)"), ("e", "BGP"), ("e", "LACP")]
    H = 50 + len(rows) * RH + 30
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="sans-serif" font-size="11">',
         f'<rect width="{W}" height="{H}" fill="#fff"/>',
         f'<text x="10" y="18" font-size="13" font-weight="bold">{title}</text>',
         f'<text x="10" y="34" fill="#555">100ms 칸, 진할수록 많이 지나감 (칸당 최대 40 = 흐름 4개 × 10). 빨간 선 = 장애(T0)·복구(T1)</text>']
    x0 = LW
    for wi, (nm, base, a, b) in enumerate(wins):
        y = 50
        for r in rows:
            if r[0] == "h":
                if wi == 0: s.append(f'<text x="10" y="{y+12}" font-weight="bold">{r[1]}</text>')
            elif r[0] == "l":
                if wi == 0: s.append(f'<text x="18" y="{y+12}">{r[2]}</text>')
                for j in range(ncol[wi]):
                    v = cnt.get((wi, r[1], r[2], j), 0)
                    if v: s.append(f'<rect x="{x0+j*CW}" y="{y+2}" width="{CW}" height="{RH-4}" fill="#1f5fbf" fill-opacity="{min(1, v/40):.2f}"/>')
                s.append(f'<rect x="{x0}" y="{y+2}" width="{ncol[wi]*CW}" height="{RH-4}" fill="none" stroke="#ddd"/>')
            else:
                if wi == 0: s.append(f'<text x="18" y="{y+12}">{r[1]}</text>')
                for t, e in ev:
                    if e.startswith(r[1]) and base + a <= t < base + b:
                        xx = x0 + (t - base - a) / B * CW
                        s.append(f'<line x1="{xx:.1f}" y1="{y+2}" x2="{xx:.1f}" y2="{y+RH-2}" stroke="#333"/>')
            y += RH
        mx = x0 + (-a) / B * CW
        s.append(f'<line x1="{mx}" y1="44" x2="{mx}" y2="{y}" stroke="#d22" stroke-width="1.5"/>')
        s.append(f'<text x="{mx+3}" y="{y+14}" fill="#d22">{nm.split()[1]}</text>')
        for k in range(int(a), int(b) + 1):
            xx = x0 + (k - a) / B * CW
            s.append(f'<text x="{xx}" y="{y+26}" fill="#777" text-anchor="middle">{k:+d}s</text>')
        x0 += ncol[wi] * CW + 40
    s.append("</svg>")
    open(out, "w").write("\n".join(s))

def trim(d, T0, T1):
    """저장소에 올릴 pcap 을 T0-1~T0+4, T1-1~T1+5 초만 남긴다"""
    import glob
    for f in glob.glob(f"{d}/*.pcap"):
        raw = open(f, "rb").read(); hdr = raw[:24]
        e = "<" if hdr[:4] == b"\xd4\xc3\xb2\xa1" else ">"
        out = [hdr]; i = 24
        while i + 16 <= len(raw):
            s_, us, cl, _ = struct.unpack(e + "IIII", raw[i:i + 16]); t = s_ + us / 1e6
            if T0 - 1 <= t < T0 + 4 or T1 - 1 <= t < T1 + 5: out.append(raw[i:i + 16 + cl])
            i += 16 + cl
        open(f, "wb").write(b"".join(out))

if sys.argv[1] == "flows": flows(sys.argv[2])
elif sys.argv[1] == "trim": trim(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]))
else: timeline(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5], sys.argv[6])
