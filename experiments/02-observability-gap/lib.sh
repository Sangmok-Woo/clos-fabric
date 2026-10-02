# 공통 변수. 다른 스크립트가 source 한다.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXP01=$HERE/../01-http-mtu     # 환경 준비와 장애 주입은 실험 01 것을 그대로 쓴다
IMG=$HERE/img
WIN=/mnt/c/Users/sangmok/Desktop/Claude/clos-fabric/experiments/$(basename "$HERE")/img  # 윈도우 사본
PROM=http://localhost:9090
GRAFANA=http://localhost:3000

CLIENT=v1; SERVER_IP=10.10.10.33; PORT=8080
FILE=video-small.mp4           # 68MB. 실험 01 setup.sh 가 v3 /srv 에 올려둔다

c() { echo "clab-clos-$1"; }

# Prometheus 즉시 질의. 결과가 여러 줄이면 "라벨 값" 으로 한 줄씩.
q() {
  curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | python3 -c '
import json, sys
r = json.load(sys.stdin)["data"]["result"]
if not r: print(0)
for x in r:
    m = x["metric"]
    who = ":".join(m[k] for k in ("node", "ifname", "host", "alertname") if k in m)
    if "link" in m: who += " (" + m["link"] + ")"
    v = float(x["value"][1])
    print((who + " " if who else "") + (str(int(v)) if v == int(v) else f"{v:.1f}"))'
}

# 한 번 전송. 리프의 경로 캐시를 비워야 플로우가 스파인 두 대로 갈린다 (실험 01 RESULTS Phase 1)
fetch() {
  for n in leaf1 leaf3; do docker exec "$(c $n)" ip route flush cache; done
  docker exec "$(c $CLIENT)" curl -s -o /dev/null --max-time "${1:-6}" \
    -w "%{size_download} %{time_total}" "http://$SERVER_IP:$PORT/$FILE"
}

render() {   # render <파일이름>  — 실행 중인 Grafana 대시보드를 PNG로
  mkdir -p "$IMG"
  curl -s -m 90 "$GRAFANA/render/d/clos-fabric/?width=1500&height=1750&theme=light&kiosk&from=now-10m&to=now" \
    -o "$IMG/$1.png" && echo "  img/$1.png"
  [ -d "$(dirname "$WIN")" ] && mkdir -p "$WIN" && cp "$IMG/$1.png" "$WIN/"
}
