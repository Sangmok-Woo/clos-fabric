# 공통 변수. 다른 스크립트가 source 한다.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE=$HERE/state          # 원래 값 기록 (teardown 이 되돌릴 때 씀)
IMG=$HERE/img
WIN=/mnt/c/Users/sangmok/Desktop/Claude/clos-fabric/experiments/$(basename "$HERE")/img  # 윈도우 사본
PROM=http://localhost:9090
GRAFANA=http://localhost:3000

# 관찰 구간: v1(leaf1) -> v3(leaf3). 둘 다 VNI 10010, 10.10.10.0/24.
CLIENT=v1; CLIENT_IP=10.10.10.11
SERVER=v3; SERVER_IP=10.10.10.33
PORT=8080
FILE=video-small.mp4       # 68MB (68,475,086B). setup.sh 가 v3 /srv 에 올린다
FILE_BYTES=68475086

UNDERLAY_MTU=9216
OVERLAY_MTU=9000           # VXLAN 50바이트를 붙여도 9216 안에 들어가는 값

# 패브릭 링크 (노드:인터페이스). 스파인끼리는 링크가 없다.
FABRIC_IFS="leaf1:eth1 leaf1:eth2 leaf2:eth1 leaf2:eth2 leaf3:eth1 leaf3:eth2 leaf4:eth1 leaf4:eth2
spine1:eth1 spine1:eth2 spine1:eth3 spine1:eth4 spine2:eth1 spine2:eth2 spine2:eth3 spine2:eth4"
# 오버레이 쪽 (브리지 + VXLAN + 호스트 포트 + 호스트 NIC)
OVERLAY_IFS="leaf1:br10010 leaf1:vni10010 leaf1:eth4 leaf3:br10010 leaf3:vni10010 leaf3:eth4 v1:eth1 v3:eth1"

c()       { echo "clab-clos-$1"; }
mtu_of()  { docker exec "$(c "${1%%:*}")" cat "/sys/class/net/${1##*:}/mtu"; }
set_mtu() { docker exec "$(c "${1%%:*}")" ip link set dev "${1##*:}" mtu "$2"; }

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

# 한 번 전송. 리프의 경로 캐시를 비워야 플로우가 스파인 두 대로 갈린다.
# 비우지 않았을 때는 68MB 8회가 모두 spine1 로 갔다 (옛 실험 01에서 확인).
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
