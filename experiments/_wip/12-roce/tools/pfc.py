#!/usr/bin/env python3
"""PFC 흉내 — 큐가 XOFF 를 넘으면 한 홉 앞 장비의 같은 클래스(RoCE, DSCP 26) 줄을 멈추고, XON 아래로 내려가면 푼다.
WSL 기본 네임스페이스에서 root 로:  pfc.py <설정 json> <로그 디렉터리>

veth 에는 802.1Qbb PAUSE 프레임이 없다. 그래서 "멈춰"를 프레임 대신 앞 장비 tc 의 plug qdisc(block/release)로 낸다.
감시 지점마다 스레드 하나가 ~2.5ms 간격으로 큐 깊이(backlog)를 읽는다. 진짜 스위치는 ns~µs 에 반응하므로,
여기서는 그만큼 헤드룸(XOFF 위로 남겨 둔 버퍼)을 크게 잡아야 드랍이 안 난다.

한 대상이 여러 감시 지점에서 동시에 멈춰질 수 있다(예: g1 은 leaf1 의 두 업링크 어느 쪽이 차도 멈춘다).
대상마다 "멈춰 달라는 쪽 수"를 세서 0 → 1 일 때 멈추고 1 → 0 일 때 푼다.

설정 json:
  {"watch": [{"name": "leaf3:eth5", "node": "leaf3", "dev": "eth5", "handle": "10:", "xoff": 262144, "xon": 131072,
              "targets": ["spine1:eth3", "spine2:eth3"]}, ...],
   "targets": {"spine1:eth3": {"node": "spine1", "dev": "eth3", "parent": "1:1"}, "g1": {"node": "host", "dev": "g1", "parent": "1:10"}, ...}}
"""
import json, os, signal, subprocess, sys, threading, time

stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())

def pid(node):
    return subprocess.check_output(["docker", "inspect", "-f", "{{.State.Pid}}", f"clab-clos-{node}"], text=True).strip()

def ns(node):
    return [] if node == "host" else ["nsenter", "-t", pid(node), "-n"]

class Target:
    def __init__(self, name, node, dev, parent):
        self.name, self.cmd = name, ns(node) + ["tc", "qdisc", "change", "dev", dev, "parent", parent, "handle", "11:", "plug"]
        self.holders = 0
        self.lock = threading.Lock()
        self.pauses = 0
        self.paused_ms = 0.0
        self.since = None

    def hold(self, t0):
        with self.lock:
            self.holders += 1
            if self.holders == 1:
                subprocess.run(self.cmd + ["block"], check=False)
                self.pauses += 1
                self.since = time.monotonic()
                return True
        return False

    def release(self):
        with self.lock:
            self.holders -= 1
            if self.holders == 0:
                subprocess.run(self.cmd + ["release_indefinite"], check=False)
                self.paused_ms += (time.monotonic() - self.since) * 1000
                self.since = None

    def close(self):
        with self.lock:
            if self.holders:
                subprocess.run(self.cmd + ["release_indefinite"], check=False)
                self.paused_ms += (time.monotonic() - self.since) * 1000
                self.holders = 0


def watcher(w, targets, log, t0, stats):
    read = ns(w["node"]) + ["tc", "-s", "-j", "qdisc", "show", "dev", w["dev"]]
    paused = False
    peak = 0
    xoffs = 0
    while not stop.is_set():
        out = subprocess.run(read, capture_output=True, text=True).stdout
        try:
            q = next(q for q in json.loads(out) if q.get("handle") == w["handle"])
            backlog = q.get("backlog", 0)
        except (ValueError, StopIteration):
            backlog = 0
        peak = max(peak, backlog)
        ms = (time.monotonic() - t0) * 1000
        if not paused and backlog > w["xoff"]:
            paused = True
            xoffs += 1
            for t in w["targets"]:
                targets[t].hold(t0)
            log.write(f"{ms:.1f},{w['name']},XOFF,{backlog}\n")
        elif paused and backlog < w["xon"]:
            paused = False
            for t in w["targets"]:
                targets[t].release()
            log.write(f"{ms:.1f},{w['name']},XON,{backlog}\n")
        time.sleep(0.001)
    if paused:
        for t in w["targets"]:
            targets[t].release()
    stats[w["name"]] = {"xoff": xoffs, "peak_backlog": peak}


def main():
    cfg, logdir = json.load(open(sys.argv[1])), sys.argv[2]
    os.makedirs(logdir, exist_ok=True)
    targets = {k: Target(k, **v) for k, v in cfg["targets"].items()}
    log = open(os.path.join(logdir, "pfc-timeline.csv"), "w", buffering=1)
    log.write("ms,watch,event,backlog_bytes\n")
    t0 = time.monotonic()
    stats = {}
    threads = [threading.Thread(target=watcher, args=(w, targets, log, t0, stats)) for w in cfg["watch"]]
    for th in threads:
        th.start()
    # join() 으로 바로 기다리면 Python 3.13+ 에서 그동안 신호 처리기가 돌지 않아 SIGTERM 을 영영 못 받는다.
    # 0.2초마다 깨어나 stop 을 확인한다
    while not stop.wait(0.2):
        pass
    for th in threads:
        th.join()
    for t in targets.values():
        t.close()
    json.dump({"watch": stats,
               "paused": {k: {"pauses": t.pauses, "paused_ms": round(t.paused_ms, 1)} for k, t in targets.items()}},
              open(os.path.join(logdir, "pfc.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
