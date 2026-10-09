#!/usr/bin/env python3
"""DCQCN 흉내 — rxe(Soft-RoCE)에 없는 혼잡 제어를 NIC 밖에서 돌린다. WSL 기본 네임스페이스, root.

  dcqcn.py np <로그 디렉터리>     받는 쪽(Notification Point). g3 로 들어오는 RoCE 패킷에서 CE 도장을 보면
                                   보낸 서버로 CNP 를 패킷으로 보낸다 (UDP 4792, 패브릭을 실제로 건넌다)
  dcqcn.py rp <로그 디렉터리>     보내는 쪽(Reaction Point). g1·g2·g4 에서 CNP 를 받아 DCQCN 규칙으로
                                   송신 속도를 정하고, gN 의 tc htb 클래스(RoCE 클래스) 속도를 바꾼다

진짜 NIC 와 다른 점 (README 에 적는다)
  - CNP 는 RoCEv2 의 BTH opcode 0x81 이 아니라 평범한 UDP 4792 다. 4791 로 보내면 rxe 가 받아 버린다
  - 타이머가 µs 가 아니라 ms 다 (tc 를 바꾸는 데 수 ms 가 든다). 그래서 g 와 증가 폭도 그에 맞춰 키웠다
  - 속도 조절은 NIC 의 송신 스케줄러가 아니라 gN 의 htb 클래스다
SIGTERM 을 받으면 통계를 <로그 디렉터리>/np.json 또는 rp.json 에 쓰고 끝난다.
"""
import json, os, select, signal, socket, struct, subprocess, sys, time

CNP_PORT = 4792
CNP_TOS = 0xC0                       # CNP 는 CS6. RoCE 클래스(DSCP 26)와 다른 줄로 가서 PFC 에 같이 묶이지 않는다
SENDERS = {1: "172.16.21.10", 2: "172.16.22.10", 4: "172.16.24.10"}
RECEIVER = (3, "172.16.23.10")

# DCQCN 파라미터 (논문 Zhu et al., SIGCOMM 2015 의 구조 그대로, 시간 단위만 ms 로)
LINE = 1000.0      # Mbit/s. NIC 선로 속도 역할 (gN htb 상한)
RMIN = 5.0         # 최소 속도
G = 1 / 16         # α 갱신 가중치 (논문 1/256, µs 타이머 기준)
K_MS = 5           # α 감쇠 타이머 (논문 55µs)
T_MS = 5           # 속도 증가 타이머 (논문 55µs)
F = 5              # fast recovery 단계 수
R_AI = 10.0        # additive increase 폭 (Mbit/s)
R_HAI = 50.0       # hyper increase 폭
CNP_GAP_MS = 2     # NP 가 한 송신자에게 CNP 를 보내는 최소 간격 (논문 50µs)
REDUCE_GAP_MS = 10 # RP 가 한 번 깎은 뒤 다시 깎기까지 기다리는 시간 (Mellanox 의 rate_reduce_monitor_period).
                   # 깎은 효과가 큐에 나타나기 전(tc 적용 + 큐 비우기)에 온 CNP 로 또 깎으면 바닥까지 떨어진다

stop = False
def _term(*_):
    global stop
    stop = True
signal.signal(signal.SIGTERM, _term)
signal.signal(signal.SIGINT, _term)

def now_ms():
    return time.monotonic() * 1000

def bind_dev(sock, dev):
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, dev.encode())


def run_np(logdir):
    n, ip = RECEIVER
    # g3 로 들어오는 패킷을 앞 64바이트만 본다 (이더넷 14 + IP 20 + UDP 8 이면 충분)
    rx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0800))
    rx.bind((f"g{n}", 0))
    rx.settimeout(0.2)
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    bind_dev(tx, f"vg{n}")
    tx.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, CNP_TOS)
    tx.bind((ip, 0))
    by_ip = {v: k for k, v in SENDERS.items()}
    st = {k: {"roce_pkts": 0, "ce_pkts": 0, "cnp_sent": 0} for k in SENDERS}
    last = {k: -1e9 for k in SENDERS}
    while not stop:
        try:
            pkt, addr = rx.recvfrom(64)
        except socket.timeout:
            continue
        if addr[2] == socket.PACKET_OUTGOING or len(pkt) < 38:
            continue
        if pkt[23] != 17 or struct.unpack("!H", pkt[36:38])[0] != 4791:   # UDP 4791 = RoCEv2
            continue
        src = socket.inet_ntoa(pkt[26:30])
        k = by_ip.get(src)
        if k is None:
            continue
        st[k]["roce_pkts"] += 1
        if pkt[15] & 3 != 3:                                            # ECN 두 비트가 11 = CE
            continue
        st[k]["ce_pkts"] += 1
        t = now_ms()
        if t - last[k] < CNP_GAP_MS:
            continue
        last[k] = t
        # CNP 본문: 받는 쪽 번호와 시각 (흉내라서 BTH 대신 사람이 읽을 수 있는 값)
        tx.sendto(f"CNP from g{n} t={t:.1f}".encode(), (src, CNP_PORT))
        st[k]["cnp_sent"] += 1
    json.dump({f"g{k}": v for k, v in st.items()}, open(os.path.join(logdir, "np.json"), "w"), indent=1)


class Sender:
    def __init__(self, n):
        self.n = n
        self.rc = LINE          # 지금 속도
        self.rt = LINE          # 목표 속도 (깎기 직전 속도를 기억했다가 회복할 때 쓴다)
        self.alpha = 1.0
        self.stage = 0          # 마지막 CNP 이후 지난 증가 타이머 수
        self.cnp = 0
        self.cuts = 0
        self.last_cut = -1e9
        self.cnp_since_tick = False
        self.applied = None
        self.min_rc = LINE

    def on_cnp(self):
        self.cnp += 1
        self.cnp_since_tick = True          # 이번 타이머 구간에는 올리지 않는다
        t = now_ms()
        if t - self.last_cut < REDUCE_GAP_MS:
            return False
        self.last_cut = t
        self.cuts += 1
        # 혼잡 신호: 지금 속도를 목표로 기억하고, α 에 비례해 깎는다
        self.rt = self.rc
        self.rc = max(RMIN, self.rc * (1 - self.alpha / 2))
        self.alpha = (1 - G) * self.alpha + G
        self.stage = 0
        self.min_rc = min(self.min_rc, self.rc)
        return True

    def on_alpha_timer(self):
        if not self.cnp_since_tick:
            self.alpha = (1 - G) * self.alpha       # 조용하면 α 가 줄어 다음 깎기가 약해진다

    def on_increase_timer(self):
        if self.cnp_since_tick:
            self.cnp_since_tick = False
            return
        self.stage += 1
        if self.stage > 2 * F:
            self.rt = min(LINE, self.rt + R_HAI)    # hyper increase
        elif self.stage > F:
            self.rt = min(LINE, self.rt + R_AI)     # additive increase
        self.rc = min(LINE, (self.rt + self.rc) / 2)  # fast recovery: 목표 쪽으로 반씩

    def apply(self):
        # tc 를 바꾸는 데 수 ms 가 든다 → 2% 넘게 달라졌을 때만
        if self.applied and abs(self.rc - self.applied) / self.applied < 0.02:
            return
        r = f"{max(RMIN, self.rc):.0f}mbit"
        subprocess.run(["tc", "class", "change", "dev", f"g{self.n}", "parent", "1:", "classid", "1:10",
                        "htb", "rate", r, "ceil", r, "quantum", "60000"], check=False)
        self.applied = self.rc


def run_rp(logdir):
    socks = {}
    for k, ip in SENDERS.items():
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        bind_dev(s, f"vg{k}")
        s.bind((ip, CNP_PORT))
        s.setblocking(False)
        socks[s] = Sender(k)
    senders = list(socks.values())
    log = open(os.path.join(logdir, "rp-timeline.csv"), "w")
    log.write("ms,sender,event,rate_mbit,alpha\n")
    t0 = now_ms()
    next_tick = t0 + T_MS
    while not stop:
        timeout = max(0, next_tick - now_ms()) / 1000
        r, _, _ = select.select(list(socks), [], [], timeout)
        for s in r:
            while True:
                try:
                    s.recv(256)
                except BlockingIOError:
                    break
                snd = socks[s]
                ev = "cut" if snd.on_cnp() else "cnp"     # cnp = 받았지만 깎은 지 얼마 안 돼서 넘김
                log.write(f"{now_ms() - t0:.1f},g{snd.n},{ev},{snd.rc:.1f},{snd.alpha:.3f}\n")
            socks[s].apply()
        if now_ms() >= next_tick:
            next_tick += T_MS          # K_MS == T_MS 라서 타이머 하나로 둘 다 돌린다
            for snd in senders:
                snd.on_alpha_timer()
                snd.on_increase_timer()
                snd.apply()
                log.write(f"{now_ms() - t0:.1f},g{snd.n},tick,{snd.rc:.1f},{snd.alpha:.3f}\n")
    log.close()
    json.dump({f"g{s.n}": {"cnp_rcvd": s.cnp, "cuts": s.cuts, "min_rate_mbit": round(s.min_rc, 1), "end_rate_mbit": round(s.rc, 1),
                           "end_alpha": round(s.alpha, 3)} for s in senders},
              open(os.path.join(logdir, "rp.json"), "w"), indent=1)


if __name__ == "__main__":
    role, logdir = sys.argv[1], sys.argv[2]
    os.makedirs(logdir, exist_ok=True)
    {"np": run_np, "rp": run_rp}[role](logdir)
