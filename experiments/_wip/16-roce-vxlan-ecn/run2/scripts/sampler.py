#!/usr/bin/env python3
"""1초마다 계수기를 한 줄씩 CSV 로 (누적값 그대로. 차분은 분석 때).  WSL root.

  sampler.py <out.csv> <초>

열
  t                          시작 후 초
  outer_vx, outer_ce         leaf3:eth1 ingress 바깥 VXLAN 패킷 / 그중 바깥 CE   (장애1 pedit 이전에 센다)
  in_ce, in_ect0, in_ect1, in_notect   xg3 ingress(디캡 후, 수신 서버 앞) 안쪽 ECN 별 패킷
  rx_g1_B, rx_g2_B, rx_g4_B  xg3 ingress 송신자별 바이트
  ece, cnp                   xg3 egress 수신측 알림: ECE 켜진 TCP / CNP(UDP 4792)
  sp_drop, sp_mark, sp_backlog   spine1:eth3 병목 RED(10:) 드랍·표시·큐 바이트
  lf_drop, lf_mark, lf_backlog   leaf3:eth6 병목(대조군)
  nak_g3, dup_g3             rxe_x3 out_of_seq_request(NAK 보냄) / duplicate_request
  retry_gN                   rxe_xN completer_retry_err (송신측 재전송 타이머)
  tcp_retrans, tcp_dlv_ce    /proc/net/snmp RetransSegs, netstat TCPDeliveredCE (기본 netns 전체)
"""
import csv, json, os, subprocess, sys, time

out, dur = sys.argv[1], float(sys.argv[2])


def pid(n):
    return subprocess.check_output(["docker", "inspect", "-f", "{{.State.Pid}}", f"clab-clos-{n}"], text=True).strip()


PID = {n: pid(n) for n in ("leaf3", "spine1")}


def j(cmd, ns=None):
    if ns:
        cmd = ["nsenter", "-t", PID[ns], "-n"] + cmd
    try:
        return json.loads(subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL) or "[]")
    except Exception:
        return []


def fstats(lst):
    r = {}
    for f in lst:
        a = f.get("options", {}).get("actions")
        if a:
            s = a[0].get("stats", {})
            r[f["pref"]] = (s.get("packets", 0), s.get("bytes", 0))
    return r


def qstats(lst):
    for q in lst:
        if q.get("handle") == "10:":
            return q.get("drops", 0), q.get("marked", 0), q.get("backlog", 0)
    return 0, 0, 0


def hw(n, k):
    try:
        return int(open(f"/sys/class/infiniband/rxe_x{n}/ports/1/hw_counters/{k}").read())
    except Exception:
        return 0


def nstat():
    v = {}
    for fn in ("/proc/net/snmp", "/proc/net/netstat"):
        lines = open(fn).read().splitlines()
        for a, b in zip(lines[::2], lines[1::2]):
            ka, kb = a.split(), b.split()
            for x, y in zip(ka[1:], kb[1:]):
                v[ka[0] + x] = int(y)
    return v.get("Tcp:RetransSegs", 0), v.get("TcpExt:TCPDeliveredCE", 0)


cols = ["t", "outer_vx", "outer_ce", "in_ce", "in_ect0", "in_ect1", "in_notect", "rx_g1_B", "rx_g2_B", "rx_g4_B",
        "ece", "cnp", "sp_drop", "sp_mark", "sp_backlog", "lf_drop", "lf_mark", "lf_backlog",
        "nak_g3", "dup_g3", "retry_g1", "retry_g2", "retry_g4", "tcp_retrans", "tcp_dlv_ce"]
w = csv.writer(open(out, "w", newline=""))
w.writerow(cols)
t0 = time.monotonic()
k = 0
while True:
    t = time.monotonic() - t0
    o = fstats(j(["tc", "-s", "-j", "filter", "show", "dev", "eth1", "ingress"], "leaf3"))
    i = fstats(j(["tc", "-s", "-j", "filter", "show", "dev", "xg3", "ingress"]))
    e = fstats(j(["tc", "-s", "-j", "filter", "show", "dev", "xg3", "egress"]))
    sp = qstats(j(["tc", "-s", "-j", "qdisc", "show", "dev", "eth3"], "spine1"))
    lf = qstats(j(["tc", "-s", "-j", "qdisc", "show", "dev", "eth6"], "leaf3"))
    rt, dce = nstat()
    g = lambda d, p, b=0: d.get(p, (0, 0))[b]
    w.writerow([round(t, 2), g(o, 11), g(o, 12), g(i, 11), g(i, 12), g(i, 14), g(i, 13), g(i, 21, 1), g(i, 22, 1), g(i, 24, 1),
                g(e, 11), g(e, 12), *sp, *lf, hw(3, "out_of_seq_request"), hw(3, "duplicate_request"),
                hw(1, "completer_retry_err"), hw(2, "completer_retry_err"), hw(4, "completer_retry_err"), rt, dce])
    k += 1
    if t >= dur:
        break
    time.sleep(max(0, t0 + k - time.monotonic()))
