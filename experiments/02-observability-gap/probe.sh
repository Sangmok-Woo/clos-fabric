#!/usr/bin/env bash
# 장애를 넣고 전송을 반복한 뒤, 그 순간 모니터링이 무엇을 봤는지 Prometheus 에 묻는다.
# 사용법: ./probe.sh [시도 횟수]      (기본 8회)
#         RENDER=이름 ./probe.sh       끝에 대시보드 PNG 를 img/이름.png 로
set -eu
. "$(dirname "$0")/lib.sh"
N=${1:-8}

"$EXP01/fault.sh" inject spine1 >/dev/null || exit 1
echo ">>> spine1:eth3 MTU 1500 (실험 01 fault.sh)"
echo "=== 전송 $N회 (68MB, 6초 제한) ==="
ok=0; stuck=0
for i in $(seq "$N"); do
  read -r bytes t <<<"$(fetch 6)"
  if [ "$bytes" -ge 68000000 ]; then ok=$((ok+1)); r="완료 ${t}초"; else stuck=$((stuck+1)); r="정지 (${bytes}B)"; fi
  echo "  $i: $r"
done
echo "  완료 $ok / 정지 $stuck"

sleep 10   # scrape(5초) 두 번 + 알람 평가
echo "=== 모니터링이 본 것 ==="
echo "  세션 Established: $(q 'sum(clos_bgp_peers_established)') / $(q 'sum(clos_bgp_peers_expected)')"
echo "  울리는 알람:"
q 'count by (alertname) (ALERTS{alertstate="firing"})' | sed 's/^/    /'
echo "  드랍이 찍힌 포트 (최근 2분):"
q 'increase(clos_if_rx_dropped_total[2m]) > 0 or increase(clos_if_tx_dropped_total[2m]) > 0' \
  | sed 's/^/    /'
echo "  MTU가 다른 패브릭 포트:"
q 'clos_if_mtu{kind="fabric"} != on() group_left() quantile(0.5, clos_if_mtu{kind="fabric"})' \
  | sed 's/^/    /'
echo "  v3 TCP 재전송 (최근 2분): $(q 'increase(clos_host_tcp_retranssegs_total{host="v3"}[2m])' | awk '{print $NF}')개"

[ -n "${RENDER:-}" ] && render "$RENDER"
"$EXP01/fault.sh" restore | head -1
