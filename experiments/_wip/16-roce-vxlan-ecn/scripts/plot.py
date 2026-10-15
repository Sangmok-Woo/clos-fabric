#!/usr/bin/env python3
"""data/*.csv 로 figures/*.png 를 그린다. 사용: python plot.py  (matplotlib 필요)
  throughput.png      합계 처리량 1초 시계열 — 정상 / 장애1 / 장애2 / 대조군(장애1) 겹쳐 그리기
  rtt.png             v1 → v3 RTT 1초 시계열 (같은 네 조건)
  ce-outer-inner.png  스파인 마킹(바깥 CE) vs 수신측 안쪽 CE — 정상 / 장애1 / 대조군+장애1
  retrans-ece.png     재전송 수와 ECE(수신측 CE 를 돌려받아 송신이 확인한 수) — 조건별
값은 3회 평균, 막대 위 숫자, 선 끝에 이름표."""
import csv, glob, os, statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")
FIG = os.path.join(HERE, "..", "figures")
os.makedirs(FIG, exist_ok=True)

SURF, INK, INK2, GRID = "#fcfcfb", "#1a1a19", "#5f5e58", "#e4e3dc"
COND = [  # (이름, 표시, 색)  범주 색 순서 고정: blue, orange, aqua, yellow
    ("baseline", "정상", "#2a78d6"),
    ("fault-decap", "장애1 디캡 CE 누락", "#eb6834"),
    ("fault-encap", "장애2 캡슐화 ECT 누락", "#1baf7a"),
    ("control-decap", "대조군 + 장애1", "#eda100"),
]
for f in ("Malgun Gothic", "NanumGothic", "AppleGothic"):
    if any(f in x.name for x in matplotlib.font_manager.fontManager.ttflist):
        plt.rcParams["font.family"] = f
        break
plt.rcParams.update({"axes.unicode_minus": False, "figure.facecolor": SURF, "axes.facecolor": SURF,
                     "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
                     "text.color": INK, "font.size": 10})

def series(name, col):
    """조건 3회의 같은 초 값을 평균한 시계열"""
    runs = []
    for p in sorted(glob.glob(os.path.join(DATA, f"{name}-r*.csv"))):
        rows = list(csv.DictReader(open(p, encoding="utf-8")))
        runs.append([float(r[col]) if r[col] not in ("", None) else None for r in rows])
    if not runs:
        return []
    n = min(len(r) for r in runs)
    out = []
    for i in range(n):
        v = [r[i] for r in runs if r[i] is not None]
        out.append(statistics.mean(v) if v else None)
    return out

summ = list(csv.DictReader(open(os.path.join(DATA, "summary.csv"), encoding="utf-8")))
def mean_of(name, col):
    v = [float(r[col]) for r in summ if r["name"] == name and r[col] != ""]
    return statistics.mean(v) if v else 0

def style(ax, title, ylabel):
    ax.set_title(title, loc="left", fontsize=12, color=INK, pad=10)
    ax.set_ylabel(ylabel)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.tick_params(length=0)

def lines(col, title, ylabel, fname, ymax=None):
    fig, ax = plt.subplots(figsize=(9, 4.2))
    ends = []
    for name, label, color in COND:
        y = series(name, col)
        if not y:
            continue
        x = [i + 1 for i, v in enumerate(y) if v is not None]
        yy = [v for v in y if v is not None]
        ax.plot(x, yy, color=color, linewidth=2, label=label)
        ends.append([yy[-1], label, color, x[-1]])
    # 선 끝 이름표 — 겹치지 않게 세로로 벌린다
    lo, hi = ax.get_ylim() if ymax is None else (0, ymax)
    gap = (hi - lo) * 0.07
    ends.sort(key=lambda e: e[0])
    for i in range(1, len(ends)):
        ends[i][0] = max(ends[i][0], ends[i - 1][0] + gap)
    for yv, label, color, xe in ends:
        ax.annotate(label, (xe, yv), xytext=(8, 0), textcoords="offset points", va="center", color=INK2, fontsize=9)
    if ymax:
        ax.set_ylim(0, ymax)
    ax.set_xlabel("초")
    ax.legend(loc="upper left", frameon=False, ncol=4, fontsize=9, bbox_to_anchor=(0, -0.14))
    style(ax, title, ylabel)
    ax.set_xlim(right=ax.get_xlim()[1] * 1.22)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, fname), dpi=130)
    plt.close(fig)

def bars(groups, metrics, title, fname, ylabel):
    """groups: [(조건, 표시)], metrics: [(열, 표시, 색)]"""
    fig, ax = plt.subplots(figsize=(8, 4.2))
    w = 0.36
    for j, (col, mlabel, color) in enumerate(metrics):
        xs = [i + (j - (len(metrics) - 1) / 2) * (w + 0.03) for i in range(len(groups))]
        vals = [mean_of(g, col) for g, _ in groups]
        bs = ax.bar(xs, vals, width=w, color=color, label=mlabel, edgecolor=SURF, linewidth=2)
        for b, v in zip(bs, vals):
            ax.annotate(f"{v:,.0f}", (b.get_x() + b.get_width() / 2, v), xytext=(0, 3), textcoords="offset points",
                        ha="center", va="bottom", fontsize=9, color=INK)
    ax.set_xticks(range(len(groups)))
    ax.set_xticklabels([l for _, l in groups])
    ax.legend(frameon=False, loc="upper left", fontsize=9)
    style(ax, title, ylabel)
    ax.set_ylim(top=ax.get_ylim()[1] * 1.12)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, fname), dpi=130)
    plt.close(fig)

lines("thr_sum", "합계 처리량 (수신측, 3회 평균) — 병목 100Mbit", "Mbit/s", "throughput.png", ymax=110)
lines("rtt_ms", "v1 → v3 RTT (ECT ping, 3회 평균)", "ms", "rtt.png")
bars([("baseline", "정상"), ("fault-decap", "장애1"), ("control-decap", "대조군 + 장애1")],
     [("bn_marked", "병목이 찍은 CE (바깥 또는 안쪽)", "#2a78d6"), ("rx_ce", "수신 v3 가 받은 안쪽 CE", "#eb6834")],
     "CE 마킹은 일어나는데 수신측에 닿는가 (60초, 3회 평균)", "ce-outer-inner.png", "패킷")
bars([(n, l.split(" ")[0]) for n, l, _ in COND],
     [("retrans", "재전송 (iperf3 송신측 합)", "#2a78d6"), ("tx_delivered_ce", "ECE 로 돌아온 CE (송신측)", "#eb6834")],
     "재전송과 ECE (60초, 3회 평균)", "retrans-ece.png", "세그먼트")
print("figures:", sorted(os.listdir(FIG)))
