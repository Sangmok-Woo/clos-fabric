# 16번 공통 값과 함수. 각 스크립트가 source 한다. WSL root 에서 실행.
. "$(dirname "${BASH_SOURCE[0]}")/../../../_tools/lab.sh"
EXP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATA=$EXP/data
CAP=${CAP:-/root/labs/ecn16-cap}     # 전체 pcap 은 저장소 밖에 둔다
STATE=/root/labs/ecn16-state
mkdir -p "$DATA" "$CAP" "$STATE"

VNI=10010; BR=br10010; VX=vni10010
RX=v3; RX_IP=10.10.10.33                # 수신 (leaf3)
SENDERS="v1 x2 x4"                       # 송신 (leaf1, leaf2, leaf4)
declare -A LEAF=([v1]=leaf1 [x2]=leaf2 [x4]=leaf4 [v3]=leaf3)
declare -A IPOF=([v1]=10.10.10.11 [x2]=10.10.10.22 [x4]=10.10.10.44 [v3]=10.10.10.33)
declare -A PORT=([v1]=5201 [x2]=5202 [x4]=5203)

RATE=${RATE:-100mbit}
# 병목 큐: RED + ECN. 임계값 30~45KB(100Mbit 에서 약 2.4~3.6ms), 한도 600KB(약 48ms)
RED="red limit 600000 min 30000 max 45000 avpkt 1500 burst 25 probability 1.0 bandwidth $RATE ecn"

# 병목 위치. spine: spine1 → leaf3 (eth3, VXLAN 바깥 헤더 구간)  /  rxport: leaf3 → v3 (eth4, 디캡 뒤 안쪽 헤더)
BN_SPINE="spine1 eth3"
BN_RXPORT="leaf3 eth4"

bn_on() {   # bn_on <노드> <인터페이스>
  nsx "$1" tc qdisc replace dev "$2" root handle 1: htb default 10
  nsx "$1" tc class replace dev "$2" parent 1: classid 1:10 htb rate $RATE ceil $RATE
  nsx "$1" tc qdisc replace dev "$2" parent 1:10 handle 10: $RED
}
bn_off() { nsx "$1" tc qdisc del dev "$2" root 2>/dev/null; true; }

# /proc/net/netstat·snmp 에서 카운터 하나 꺼내기: ctr <노드> <이름>
ctr() {
  nsx "$1" cat /proc/net/netstat /proc/net/snmp | awk -v k="$2" '
    NR%2==1 {split($0,h," ")} NR%2==0 {split($0,v," "); for(i=2;i<=length(h);i++) if(h[i]==k) print v[i]}'
}
