#!/usr/bin/env bash
# "모니터링이 장애를 알아채는 데 걸리는 시간"을 잰다.
#
# 데이터플레인 복구(failover.sh, BFD로 1초 안에 우회)와는 다른 값이다.
# 여기서 재는 것은 관측 지연 = 장애 → BGP 세션 down → 다음 scrape → 지표 반영.
# 그래서 이 값은 scrape_interval(5초) 아래로는 못 내려간다 — 그게 핵심 교훈.
#
# 방법: spine2 를 조용히 얼리고(docker pause), Prometheus 에 저장된
# leaf1 의 established 세션이 2 미만으로 떨어진 첫 순간까지의 시간을 잰다.
# BFD off / on 두 번 재서 "BGP가 죽는 시점"의 차이가 관측 지연에 어떻게 반영되는지 본다.
set -u
cd "$(dirname "$0")/.."
PROM=localhost:9090
TARGET=${1:-spine2}
WATCH=leaf1

run_once() {
  python3 - "$PROM" "$TARGET" "$WATCH" <<'PY'
import json, subprocess, sys, time, urllib.request
prom, target, watch = sys.argv[1], sys.argv[2], sys.argv[3]

def q(expr):
    u = f"http://{prom}/api/v1/query?query=" + urllib.parse.quote(expr)
    with urllib.request.urlopen(u, timeout=5) as r:
        res = json.load(r)["data"]["result"]
    return float(res[0]["value"][1]) if res else None

expr = f'clos_bgp_peers_established{{node="{watch}"}}'
# 안정화 대기(established==2)
for _ in range(60):
    if q(expr) == 2: break
    time.sleep(1)
else:
    print("  [!] 세션이 2로 안정되지 않음 — 랩 상태 확인 필요"); sys.exit(1)

t0 = time.time()
subprocess.run(["docker", "pause", f"clab-clos-{target}"],
               check=True, stdout=subprocess.DEVNULL)
try:
    while True:
        v = q(expr)
        if v is not None and v < 2:
            break
        if time.time() - t0 > 60:
            print("  [!] 60초 안에 감지 안 됨"); sys.exit(1)
        time.sleep(0.2)
    print(f"  => 감지까지 {time.time()-t0:.1f}초")
finally:
    subprocess.run(["docker", "unpause", f"clab-clos-{target}"],
                   stdout=subprocess.DEVNULL)
    time.sleep(8)  # 세션 재수립 여유
PY
}

echo "== 감지 시간 측정 (spine2 조용한 먹통 → 모니터링이 알아챌 때까지) =="
echo
echo "[BFD 없음]"
./scripts/bfd-apply.sh off >/dev/null 2>&1 || true
sleep 5
run_once
echo
echo "[BFD 300ms×3]"
./scripts/bfd-apply.sh on >/dev/null 2>&1
sleep 5
run_once
./scripts/bfd-apply.sh off >/dev/null 2>&1 || true
echo
echo "* scrape_interval=5초가 하한이다. BFD는 'BGP가 죽는 시점'을 앞당길 뿐,"
echo "  다음 scrape 전까지는 Prometheus가 알 수 없다."
