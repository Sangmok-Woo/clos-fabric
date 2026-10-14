#!/usr/bin/env python3
"""data/runs/ → 요약 CSV + 시계열 CSV + 그림 3장.  윈도우(pandas·matplotlib)에서 실행.

  python scripts/analyze.py

만드는 것
  data/summary.csv           트랙·시나리오·반복별 한 줄 (트래픽 구간 합계·평균)
  data/summary-mean.csv      반복 3회 평균 / 표준편차
  data/timeseries-<트랙>.csv 1초 단위 (시나리오·반복별)
  figures/1-throughput.png   처리량 시계열 — 정상/장애1/장애2/대조군 겹쳐 그리기
  figures/2-ce-outer-inner.png  바깥 CE vs 안쪽 CE (정상/장애1/대조군)
  figures/3-retrans-signal.png  재전송(NAK) · 수신측 알림(ECE/CNP)
"""
import glob, json, os, re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

EXP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNS = os.path.join(EXP, "data", "runs")
FIG = os.path.join(EXP, "figures"); os.makedirs(FIG, exist_ok=True)
TRACKS = ["tcp", "dcqcn", "roce"]
TNAME = {"tcp": "B: TCP + DCTCP", "dcqcn": "A': rxe + DCQCN emulation", "roce": "A: rxe as-is (no CC)"}
SCEN = ["base", "decap", "encap", "control"]
SNAME = {"base": "normal", "decap": "fault 1: CE lost at decap", "encap": "fault 2: ECT lost at encap",
         "control": "control: bottleneck after decap + fault 1"}
# 기준 팔레트(dataviz references/palette.md) 1~4번, 고정 순서
COL = {"base": "#2a78d6", "decap": "#eb6834", "encap": "#1baf7a", "control": "#eda100"}
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e4e3df"
DIFF = ["outer_vx", "outer_ce", "in_ce", "in_ect0", "in_ect1", "in_notect", "rx_g1_B", "rx_g2_B", "rx_g4_B", "ece", "cnp",
        "sp_drop", "sp_mark", "lf_drop", "lf_mark", "nak_g3", "dup_g3", "retry_g1", "retry_g2", "retry_g4", "tcp_retrans", "tcp_dlv_ce"]


def load(tr, sc, rep):
    d = os.path.join(RUNS, tr, f"{sc}-r{rep}")
    s = pd.read_csv(os.path.join(d, "sampler.csv"))
    ts = s[["t"]].copy()
    for c in DIFF:
        ts[c] = s[c].diff()
    ts["sp_backlog"] = s["sp_backlog"]; ts["lf_backlog"] = s["lf_backlog"]
    ts["rx_mbit"] = (ts["rx_g1_B"] + ts["rx_g2_B"] + ts["rx_g4_B"]) * 8 / 1e6
    ts["retry"] = ts["retry_g1"] + ts["retry_g2"] + ts["retry_g4"]
    ts = ts.iloc[1:].reset_index(drop=True)
    ts["sec"] = range(1, len(ts) + 1)
    ts.insert(0, "rep", rep); ts.insert(0, "scenario", sc); ts.insert(0, "track", tr)
    # 트래픽이 흐른 구간 = 수신이 10Mbit 넘는 첫 초 ~ 마지막 초
    act = ts.index[ts["rx_mbit"] > 10]
    a = ts.loc[act.min():act.max()] if len(act) else ts.iloc[0:0]
    row = {"track": tr, "scenario": sc, "rep": rep, "active_s": len(a),
           "rx_mbit": a["rx_mbit"].mean()}
    for c in ["sp_mark", "sp_drop", "lf_mark", "lf_drop", "outer_ce", "in_ce", "ece", "cnp", "tcp_retrans", "tcp_dlv_ce",
              "nak_g3", "retry", "dup_g3"]:
        row[c] = a[c].sum()
    bl = "lf_backlog" if sc == "control" else "sp_backlog"
    row["queue_kb_mean"] = a[bl].mean() / 1000
    # 송신측 지표
    if tr == "tcp":
        gp, rt, cw, rtt = [], 0, [], []
        for f in sorted(glob.glob(os.path.join(d, "iperf-g*.json"))):
            j = json.load(open(f))
            gp.append(j["end"]["sum_received"]["bits_per_second"] / 1e6)
            for iv in j["intervals"]:
                st = iv["streams"][0]
                rt += st.get("retransmits", 0); cw.append(st.get("snd_cwnd", 0)); rtt.append(st.get("rtt", 0))
            n = os.path.basename(f)[6:8]
            per = [iv["streams"][0]["bits_per_second"] / 1e6 for iv in j["intervals"]]
            ts[f"tx_{n}_mbit"] = pd.Series(per[:len(ts)])
        row.update(goodput_mbit=sum(gp), goodput_min_sender=min(gp) if gp else 0, iperf_retrans=rt,
                   cwnd_kb_mean=sum(cw) / len(cw) / 1000 if cw else 0, srtt_ms_mean=sum(rtt) / len(rtt) / 1000 if rtt else 0)
    else:
        gp = []
        for f in sorted(glob.glob(os.path.join(d, "bw-g*.txt"))):
            m = [l.split() for l in open(f) if re.match(r"^\s*\d+\s+\d+\s", l)]
            gp.append(float(m[-1][3]) * 1000 if m else 0.0)
        row.update(goodput_mbit=sum(gp), goodput_min_sender=min(gp) if gp else 0)
        if tr == "dcqcn" and os.path.exists(os.path.join(d, "rp.json")):
            rp = json.load(open(os.path.join(d, "rp.json")))
            row.update(cnp_rcvd_rp=sum(v["cnp_rcvd"] for v in rp.values()), rate_cuts=sum(v["cuts"] for v in rp.values()),
                       min_rate_mbit=min(v["min_rate_mbit"] for v in rp.values()))
    return ts, row


def main():
    rows, series = [], []
    for tr in TRACKS:
        for sc in SCEN:
            for d in sorted(glob.glob(os.path.join(RUNS, tr, f"{sc}-r*"))):
                rep = int(d.rsplit("-r", 1)[1])
                ts, row = load(tr, sc, rep)
                rows.append(row); series.append(ts)
    S = pd.DataFrame(rows)
    S.to_csv(os.path.join(EXP, "data", "summary.csv"), index=False, float_format="%.1f")
    num = [c for c in S.columns if c not in ("track", "scenario", "rep")]
    M = S.groupby(["track", "scenario"], sort=False)[num].agg(["mean", "std"])
    M.columns = [f"{a}_{b}" for a, b in M.columns]
    M.to_csv(os.path.join(EXP, "data", "summary-mean.csv"), float_format="%.1f")
    T = pd.concat(series)
    for tr in TRACKS:
        T[T.track == tr].dropna(axis=1, how="all").to_csv(os.path.join(EXP, "data", f"timeseries-{tr}.csv"), index=False, float_format="%.1f")
    figs(S, T)
    pd.set_option("display.width", 250); pd.set_option("display.max_columns", 40)
    cols = ["goodput_mbit", "rx_mbit", "sp_mark", "sp_drop", "lf_mark", "lf_drop", "outer_ce", "in_ce", "ece", "cnp",
            "tcp_retrans", "nak_g3", "retry", "queue_kb_mean", "srtt_ms_mean", "cwnd_kb_mean"]
    print(S.groupby(["track", "scenario"], sort=False)[[c for c in cols if c in S]].mean().round(1).to_string())


def style(ax):
    ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(INK2)
    ax.tick_params(colors=INK2, labelsize=9)


def figs(S, T):
    plt.rcParams.update({"font.size": 10, "text.color": INK, "axes.labelcolor": INK2, "axes.titlesize": 11})
    # 1) 처리량 시계열 — 반복 3회 평균, 트랙별 패널
    fig, axs = plt.subplots(len(TRACKS), 1, figsize=(10, 9), sharex=True)
    for ax, tr in zip(axs, TRACKS):
        for sc in SCEN:
            d = T[(T.track == tr) & (T.scenario == sc)].groupby("sec")["rx_mbit"].mean()
            ax.plot(d.index, d.values, color=COL[sc], lw=2, label=SNAME[sc])
            ax.annotate(sc, (d.index[-8], d.values[-8]), color=INK2, fontsize=8, xytext=(0, 4), textcoords="offset points")
        ax.axhline(300, color=INK2, lw=0.8, ls=":")
        ax.set_title(TNAME[tr], loc="left"); ax.set_ylabel("Mbit/s at g3"); ax.set_ylim(0, 340); style(ax)
    axs[-1].set_xlabel("seconds (mean of 3 runs; dotted = 300 Mbit bottleneck)")
    axs[0].legend(loc="lower center", ncol=2, fontsize=8, frameon=False)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "1-throughput.png"), dpi=130); plt.close(fig)

    # 2) 바깥 CE vs 안쪽 CE (정상 / 장애1 / 대조군), 반복 평균
    fig, axs = plt.subplots(1, len(TRACKS), figsize=(12, 4))
    for ax, tr in zip(axs, TRACKS):
        sc3 = ["base", "decap", "control"]
        m = S[S.track == tr].groupby("scenario")[["sp_mark", "lf_mark", "outer_ce", "in_ce"]].mean()
        x = range(len(sc3)); w = 0.38
        oc = [m.loc[s, "outer_ce"] for s in sc3]; ic = [m.loc[s, "in_ce"] for s in sc3]
        b1 = ax.bar([i - w / 2 - 0.01 for i in x], oc, w, color="#2a78d6", label="outer CE (leaf3 uplink)")
        b2 = ax.bar([i + w / 2 + 0.01 for i in x], ic, w, color="#eb6834", label="inner CE (after decap, at g3)")
        for b in list(b1) + list(b2):
            ax.annotate(f"{b.get_height()/1000:.0f}k", (b.get_x() + b.get_width() / 2, b.get_height()), ha="center",
                        va="bottom", fontsize=8, color=INK2)
        ax.set_xticks(list(x)); ax.set_xticklabels(["normal", "fault 1", "control"]); ax.set_title(TNAME[tr], loc="left")
        style(ax)
    axs[0].set_ylabel("CE-marked packets per run"); axs[0].legend(fontsize=8, frameon=False, loc="upper left")
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "2-ce-outer-inner.png"), dpi=130); plt.close(fig)

    # 3) 재전송·알림 — 트랙별 두 칸: 손실 쪽(재전송/NAK, 병목 드랍)과 신호 쪽(ECE/CNP)
    fig, axs = plt.subplots(2, len(TRACKS), figsize=(12, 6.5))
    for j, tr in enumerate(TRACKS):
        m = S[S.track == tr].groupby("scenario")[["tcp_retrans", "nak_g3", "sp_drop", "lf_drop", "ece", "cnp"]].mean().reindex(SCEN)
        if tr == "tcp":
            loss, lname, sig, sname = m["tcp_retrans"], "TCP retransmitted segments", m["ece"], "ECE ACKs from receiver"
        else:
            loss, lname, sig, sname = m["nak_g3"], "NAKs sent by g3 (go-back-N)", m["cnp"], "CNPs sent by g3"
        drops = m["sp_drop"] + m["lf_drop"]
        for i, (ax, vals, name) in enumerate([(axs[0][j], loss, lname), (axs[1][j], sig, sname)]):
            bars = ax.bar(range(4), vals.values, 0.7, color=[COL[s] for s in SCEN])
            for b, v in zip(bars, vals.values):
                ax.annotate(f"{v:,.0f}", (b.get_x() + b.get_width() / 2, v), ha="center", va="bottom", fontsize=8, color=INK2)
            ax.set_xticks(range(4)); ax.set_xticklabels(["normal", "fault 1", "fault 2", "control"], fontsize=8)
            ax.set_title(f"{TNAME[tr]}\n{name}" if i == 0 else name, loc="left", fontsize=9); style(ax)
            if i == 0:
                ax.plot(range(4), drops.values, "o", color=INK, ms=6, label="bottleneck drops")
                if j == 0:
                    ax.legend(fontsize=8, frameon=False)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "3-retrans-signal.png"), dpi=130); plt.close(fig)


if __name__ == "__main__":
    main()
