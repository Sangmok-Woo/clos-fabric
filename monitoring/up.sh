#!/usr/bin/env bash
# 모니터링 시나리오 기동: 수집기 이미지 빌드 → 기존 clos 랩 정리 → 관측 포함 토폴로지 배포.
set -eu
cd "$(dirname "$0")"

echo "[*] 수집기 이미지 빌드 (clos-mon-exporter)"
docker build -q -t clos-mon-exporter:latest ./exporter >/dev/null

echo "[*] 기존 'clos' 랩 정리(있으면)"
containerlab destroy -t ../clos.clab.yml --cleanup 2>/dev/null || true
containerlab destroy -t clos-mon.clab.yml --cleanup 2>/dev/null || true

echo "[*] 모니터링 토폴로지 배포"
containerlab deploy -t clos-mon.clab.yml

cat <<'EOF'

  준비 완료.
    Grafana    → http://localhost:3000   (익명 Admin, 로그인 불필요)
    Prometheus → http://localhost:9090   (Status ▸ Rules 에서 알람 확인)
    수집기 원본 → docker exec clab-clos-exporter wget -qO- localhost:9600/metrics

  감지 시간 측정:  ./detect-time.sh
EOF
