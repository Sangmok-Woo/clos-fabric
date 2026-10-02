#!/usr/bin/env python3
"""clos-fabric 전용 Prometheus 수집기 (자작·경량).

제3자 바이너리(frr_exporter) 대신, 이 랩이 이미 쓰는 `vtysh ... json`을
그대로 docker exec 로 긁어 Prometheus 텍스트로 내보낸다. 이유:
  - 랩의 철학("내가 이해하는 스크립트")과 맞고, 배포가 단순하다 (사이드카·소켓 공유 불필요)
  - DESIGN 원칙("기대값을 상수로 박지 않는다")을 여기서 실천한다:
    라우터를 이름 규칙(clab-clos-spineN/leafN)으로 스스로 찾고,
    기대 세션 수를 토폴로지에서 계산한다 (스파인=리프수, 리프=스파인수).

/metrics 로 노출. 노드 목록은 docker 소켓으로 실시간 발견하므로,
리프를 늘려도 이 파일은 고치지 않는다.

2차(실험 05): 컨트롤플레인(세션)만 보면 MTU 장애처럼 세션은 멀쩡한데 데이터가
멈추는 장애를 못 잡는다. 그래서 데이터플레인 지표를 더한다.
  - 인터페이스별 바이트·드랍·에러·MTU (/proc/net/dev, /sys/class/net)
  - 서버별 TCP 재전송 (/proc/net/snmp)
  - 이웃별 세션 끊김 누적 (connectionsDropped) — 5초 사이에 끊겼다 붙어도 남는다
노드 수가 늘면 docker exec 가 순서대로는 느려지므로 노드별로 병렬 수집한다.

3차(실험 01): 위 지표는 전부 장비가 스스로 말하는 값(화이트박스)이라, 트래픽이 끊기면
재전송·드랍도 0이 되어 오히려 초록이 된다. 그래서 수집기가 직접 패킷을 보내 본다(블랙박스).
  - 리프마다 업링크 상대(스파인)에게 작은 ping 과 인터페이스 MTU 꽉 채운 ping 을 보낸다
  - 작은 건 되는데 큰 게 안 되면 그 링크의 MTU 문제, 둘 다 안 되면 링크·장비 문제
"""
import json
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 9600
NODE_RE = re.compile(r"^clab-clos-(spine|leaf)(\d+)$")
HOST_RE = re.compile(r"^clab-clos-([hv]\d+)$")

# 인터페이스 → 링크 이름. 포트 번호가 계산식이라(DESIGN §4) 토폴로지 파일 없이 정해진다:
# spineS:ethL ↔ leafL:ethS, 리프 eth3/eth4 는 서버 쪽.
IF_SH = ('for i in /sys/class/net/eth*; do echo "mtu ${i##*/} $(cat $i/mtu)"; done; '
         'cat /proc/net/dev; ip -4 -o addr show | sed "s/^/addr /"')


def sh(args, timeout=8):
    return subprocess.check_output(args, timeout=timeout, stderr=subprocess.DEVNULL)


def discover():
    """실행 중인 컨테이너에서 스파인/리프만 골라 (이름, 역할, 번호)로 돌려준다."""
    out = sh(["docker", "ps", "--format", "{{.Names}}"]).decode()
    nodes = []
    for name in out.split():
        m = NODE_RE.match(name)
        if m:
            nodes.append((name, m.group(1), int(m.group(2))))
    return nodes


def discover_hosts():
    out = sh(["docker", "ps", "--format", "{{.Names}}"]).decode()
    return sorted(m.group(1) for m in map(HOST_RE.match, out.split()) if m)


def vtysh_json(node, cmd):
    return json.loads(sh(["docker", "exec", node, "vtysh", "-c", cmd]))


def link_of(role, num, ifname):
    """(링크 이름, 종류). 종류는 fabric(스파인↔리프) / host(리프↔서버)."""
    port = int(ifname[3:])
    if role == "spine":
        return f"spine{num}-leaf{port}", "fabric"
    if port <= 2:
        return f"spine{port}-leaf{num}", "fabric"
    return f"leaf{num}-host", "host"


def interfaces(node):
    """eth0(관리망)을 뺀 ethN 의 {이름: {mtu, rx_bytes, ...}}. exec 한 번으로 끝낸다."""
    out = sh(["docker", "exec", node, "sh", "-c", IF_SH]).decode()
    ifs = {}
    for line in out.splitlines():
        if line.startswith("addr "):
            f = line.split()   # addr 242: eth2 inet 10.1.2.5/31 ...
            if f[2].startswith("eth") and f[3] == "inet":
                ifs.setdefault(f[2], {})["addr"] = f[4]
        elif line.startswith("mtu "):
            _, name, mtu = line.split()
            ifs.setdefault(name, {})["mtu"] = int(mtu)
        elif ":" in line and line.strip().startswith("eth"):
            name, rest = line.split(":", 1)
            f = rest.split()
            # /proc/net/dev: rx bytes packets errs drop ... | tx bytes packets errs drop ...
            ifs.setdefault(name.strip(), {}).update(
                rx_bytes=int(f[0]), rx_errors=int(f[2]), rx_dropped=int(f[3]),
                tx_bytes=int(f[8]), tx_errors=int(f[10]), tx_dropped=int(f[11]))
    return {k: v for k, v in ifs.items() if k != "eth0" and "rx_bytes" in v}


def peer_of(cidr):
    """/31 의 상대 주소. 10.1.2.5/31 → 10.1.2.4"""
    ip, plen = cidr.split("/")
    if plen != "31":
        return None
    a = ip.split(".")
    a[3] = str(int(a[3]) ^ 1)
    return ".".join(a)


def link_probe(node, ifs):
    """업링크마다 작은 ping(56B)과 MTU 꽉 채운 ping. {ifname: {"small": 0/1, "full": 0/1}}
    busybox ping 은 DF 를 못 켜지만 상관없다: 받는 쪽 veth 가 MTU 를 넘는 프레임을 버린다."""
    jobs = []
    for name, v in sorted(ifs.items()):
        peer = peer_of(v.get("addr", "x/0"))
        if not peer or "mtu" not in v:
            continue
        full = v["mtu"] - 28          # IP 20 + ICMP 8
        for size, tag in ((56, "small"), (full, "full")):
            jobs.append(f'(ping -c1 -W1 -s {size} {peer} >/dev/null 2>&1; echo "{name} {tag} $?") &')
    if not jobs:
        return {}
    out = sh(["docker", "exec", node, "sh", "-c", " ".join(jobs) + " wait"], timeout=4).decode()
    res = {}
    for line in out.splitlines():
        name, tag, rc = line.split()
        res.setdefault(name, {})[tag] = 1 if rc == "0" else 0
    return res


def tcp_stats(host):
    """/proc/net/snmp 의 Tcp 두 줄(이름/값)을 묶는다."""
    out = sh(["docker", "exec", f"clab-clos-{host}", "grep", "^Tcp:", "/proc/net/snmp"]).decode()
    names, vals = (l.split()[1:] for l in out.splitlines()[:2])
    return dict(zip(names, map(int, vals)))


def router(name, role):
    """라우터 한 대의 모든 지표. 실패한 부분은 None 으로 남긴다."""
    r = {"bgp": None, "bfd": None, "ifs": None}
    try:
        r["bgp"] = vtysh_json(name, "show ip bgp summary json")["ipv4Unicast"]
        r["bfd"] = vtysh_json(name, "show bfd peers json")
    except Exception:
        pass
    try:
        r["ifs"] = interfaces(name)
    except Exception:
        pass
    r["probe"] = _try(link_probe, name, r["ifs"]) if role == "leaf" and r["ifs"] else None
    return r


def collect():
    lines = []

    def add(name, typ, help_, samples):
        lines.append(f"# HELP {name} {help_}")
        lines.append(f"# TYPE {name} {typ}")
        for labels, val in samples:
            lines.append(f"{name}{{{labels}}} {val}" if labels else f"{name} {val}")

    t0 = time.time()
    nodes = discover()
    n_spine = sum(1 for _, r, _ in nodes if r == "spine")
    n_leaf = sum(1 for _, r, _ in nodes if r == "leaf")
    # 기대 세션 수: 스파인은 모든 리프와, 리프는 모든 스파인과 붙는다.
    expected_for = {"spine": n_leaf, "leaf": n_spine}

    up, established, expected, total, rib, bfd_up = [], [], [], [], [], []
    peer_up, peer_drops = [], []
    if_metrics = {k: [] for k in ("rx_bytes", "tx_bytes", "rx_dropped", "tx_dropped",
                                  "rx_errors", "tx_errors", "mtu")}
    probes = []

    order = sorted(nodes, key=lambda x: (x[1], x[2]))
    hosts = discover_hosts()
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda n: router(n[0], n[1]), order))
        tcp = dict(zip(hosts, pool.map(lambda h: _try(tcp_stats, h), hosts)))

    for (name, role, num), r in zip(order, results):
        short = name.replace("clab-clos-", "")
        lbl = f'node="{short}",role="{role}"'
        d = r["bgp"]
        if d is not None:
            peers = d.get("peers", {})
            est = sum(1 for p in peers.values() if p.get("state") == "Established")
            up.append((lbl, 1))
            established.append((lbl, est))
            total.append((lbl, d.get("peerCount", len(peers))))
            rib.append((lbl, d.get("ribCount", 0)))
            for pip, p in peers.items():
                plbl = f'node="{short}",peer="{p.get("desc", pip)}",addr="{pip}"'
                peer_up.append((plbl, 1 if p.get("state") == "Established" else 0))
                peer_drops.append((plbl, p.get("connectionsDropped", 0)))
            bfd_up.append((lbl, sum(1 for x in (r["bfd"] or []) if x.get("status") == "up")))
        else:
            up.append((lbl, 0))
        expected.append((lbl, expected_for[role]))

        for ifname, v in sorted((r["ifs"] or {}).items()):
            link, kind = link_of(role, num, ifname)
            ilbl = f'node="{short}",role="{role}",ifname="{ifname}",link="{link}",kind="{kind}"'
            for k in if_metrics:
                if k in v:
                    if_metrics[k].append((ilbl, v[k]))
            for tag, ok in ((r.get("probe") or {}).get(ifname) or {}).items():
                probes.append((f'{ilbl},size="{tag}"', ok))

    add("clos_up", "gauge", "vtysh 응답 여부(1=응답)", up)
    add("clos_bgp_peers_established", "gauge", "Established 상태 BGP 세션 수", established)
    add("clos_bgp_peers_expected", "gauge", "이름 규칙에서 계산한 기대 세션 수", expected)
    add("clos_bgp_peers_total", "gauge", "설정된 BGP 이웃 수", total)
    add("clos_bgp_rib_routes", "gauge", "BGP RIB 경로 수", rib)
    add("clos_bfd_peers_up", "gauge", "up 상태 BFD 세션 수", bfd_up)
    add("clos_bgp_peer_up", "gauge", "개별 이웃 up 여부(1=Established)", peer_up)
    add("clos_bgp_peer_drops_total", "counter",
        "이웃별 세션 끊김 누적(FRR connectionsDropped). scrape 사이의 짧은 플랩도 남는다", peer_drops)

    # ── 데이터플레인 (2차) ──
    for k, help_ in (("rx_bytes", "수신 바이트"), ("tx_bytes", "송신 바이트"),
                     ("rx_dropped", "수신 드랍"), ("tx_dropped", "송신 드랍"),
                     ("rx_errors", "수신 에러"), ("tx_errors", "송신 에러")):
        add(f"clos_if_{k}_total", "counter", f"인터페이스 {help_} 누적", if_metrics[k])
    add("clos_if_mtu", "gauge", "인터페이스 MTU", if_metrics["mtu"])
    for k, help_ in (("RetransSegs", "재전송한 TCP 세그먼트"), ("OutSegs", "보낸 TCP 세그먼트")):
        add(f"clos_host_tcp_{k.lower()}_total", "counter", f"서버별 {help_} 누적",
            [(f'host="{h}"', t[k]) for h, t in tcp.items() if t])

    add("clos_link_probe_success", "gauge",
        "리프→스파인 링크 ping 성공(1). size=small 은 56B, full 은 인터페이스 MTU 꽉 채운 크기", probes)

    add("clos_routers_discovered", "gauge", "발견한 라우터 수",
        [('role="spine"', n_spine), ('role="leaf"', n_leaf)])
    add("clos_scrape_duration_seconds", "gauge", "이번 수집에 걸린 시간",
        [("", round(time.time() - t0, 4))])
    return "\n".join(lines) + "\n"


def _try(fn, *a):
    try:
        return fn(*a)
    except Exception:
        return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        try:
            body = collect().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
        except Exception as e:  # 수집 실패해도 200 대신 500로 알린다
            body = f"# collect error: {e}\n".encode()
            self.send_response(500)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):  # 접근 로그 침묵
        pass


if __name__ == "__main__":
    print(f"clos collector on :{PORT}/metrics", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
