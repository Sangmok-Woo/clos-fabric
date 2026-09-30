# 공통 변수. 다른 스크립트가 source 한다.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE=$HERE/state          # 원래 값 기록 (teardown 이 되돌릴 때 씀)
PCAP=$HERE/pcap            # 캡처 결과 (WSL 쪽)
WIN=/mnt/c/Users/sangmok/Desktop/Claude/clos-fabric/experiments/$(basename "$HERE")/pcap  # 윈도우 Wireshark 용 사본

# 관찰 구간: v1(leaf1) -> v3(leaf3). 둘 다 VNI 10010, 10.10.10.0/24.
CLIENT=v1; CLIENT_IP=10.10.10.11
SERVER=v3; SERVER_IP=10.10.10.33
PORT=8080

UNDERLAY_MTU=9216
OVERLAY_MTU=9000           # VXLAN 50바이트를 붙여도 9216 안에 들어가는 값

# 패브릭 링크 (노드:인터페이스). 스파인끼리는 링크가 없다.
FABRIC_IFS="leaf1:eth1 leaf1:eth2 leaf2:eth1 leaf2:eth2 leaf3:eth1 leaf3:eth2 leaf4:eth1 leaf4:eth2
spine1:eth1 spine1:eth2 spine1:eth3 spine1:eth4 spine2:eth1 spine2:eth2 spine2:eth3 spine2:eth4"
# 오버레이 쪽 (브리지 + VXLAN + 호스트 포트 + 호스트 NIC)
OVERLAY_IFS="leaf1:br10010 leaf1:vni10010 leaf1:eth4 leaf3:br10010 leaf3:vni10010 leaf3:eth4 v1:eth1 v3:eth1"

# 캡처 지점: 리프1 업링크 2개, 스파인마다 leaf1/leaf3 방향, 리프3 업링크 2개
CAP_POINTS="leaf1:eth1 leaf1:eth2 spine1:eth1 spine1:eth3 spine2:eth1 spine2:eth3 leaf3:eth1 leaf3:eth2"

c()   { echo "clab-clos-$1"; }
pid() { docker inspect -f '{{.State.Pid}}' "$(c "$1")"; }
mtu_of() { docker exec "$(c "${1%%:*}")" cat "/sys/class/net/${1##*:}/mtu"; }
set_mtu() { docker exec "$(c "${1%%:*}")" ip link set dev "${1##*:}" mtu "$2"; }
