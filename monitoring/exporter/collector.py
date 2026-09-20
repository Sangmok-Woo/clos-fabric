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
"""
import json
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 9600
NODE_RE = re.compile(r"^clab-clos-(spine|leaf)(\d+)$")


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


def vtysh_json(node, cmd):
    return json.loads(sh(["docker", "exec", node, "vtysh", "-c", cmd]))


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
    peer_up = []

    for name, role, _num in sorted(nodes, key=lambda x: (x[1], x[2])):
        short = name.replace("clab-clos-", "")
        lbl = f'node="{short}",role="{role}"'
        try:
            d = vtysh_json(name, "show ip bgp summary json")["ipv4Unicast"]
            peers = d.get("peers", {})
            est = sum(1 for p in peers.values() if p.get("state") == "Established")
            up.append((lbl, 1))
            established.append((lbl, est))
            total.append((lbl, d.get("peerCount", len(peers))))
            rib.append((lbl, d.get("ribCount", 0)))
            for pip, p in peers.items():
                desc = p.get("desc", pip)
                is_up = 1 if p.get("state") == "Established" else 0
                peer_up.append((f'node="{short}",peer="{desc}",addr="{pip}"', is_up))
            try:
                b = vtysh_json(name, "show bfd peers json")
                bfd_up.append((lbl, sum(1 for x in b if x.get("status") == "up")))
            except Exception:
                bfd_up.append((lbl, 0))
        except Exception:
            up.append((lbl, 0))
        expected.append((lbl, expected_for[role]))

    add("clos_up", "gauge", "vtysh 응답 여부(1=응답)", up)
    add("clos_bgp_peers_established", "gauge", "Established 상태 BGP 세션 수", established)
    add("clos_bgp_peers_expected", "gauge", "이름 규칙에서 계산한 기대 세션 수", expected)
    add("clos_bgp_peers_total", "gauge", "설정된 BGP 이웃 수", total)
    add("clos_bgp_rib_routes", "gauge", "BGP RIB 경로 수", rib)
    add("clos_bfd_peers_up", "gauge", "up 상태 BFD 세션 수", bfd_up)
    add("clos_bgp_peer_up", "gauge", "개별 이웃 up 여부(1=Established)", peer_up)
    add("clos_routers_discovered", "gauge", "발견한 라우터 수",
        [('role="spine"', n_spine), ('role="leaf"', n_leaf)])
    add("clos_scrape_duration_seconds", "gauge", "이번 수집에 걸린 시간",
        [("", round(time.time() - t0, 4))])
    return "\n".join(lines) + "\n"


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
