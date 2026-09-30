# 공통 변수. 다른 스크립트가 source 한다.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE=$HERE/state          # 원래 값 기록 (teardown 이 되돌릴 때 씀)
PCAP=$HERE/pcap            # 캡처 결과

# 관찰 구간
CLIENT=; CLIENT_IP=
SERVER=; SERVER_IP=

c()   { echo "clab-clos-$1"; }
pid() { docker inspect -f '{{.State.Pid}}' "$(c "$1")"; }
