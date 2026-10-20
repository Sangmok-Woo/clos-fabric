# 실험 18 공통 값과 함수. setup.sh / run.sh / restore.sh 가 source 한다.
. "$(dirname "${BASH_SOURCE[0]}")/../../_tools/lab.sh"

VLAN=20; VNI=$((10000 + VLAN))      # DESIGN.md: VNI = 10000 + VLAN
BR=br$VNI; VX=vni$VNI
RT=65000:$VNI                        # DESIGN.md: EVPN RT 는 패브릭 공통 고정값
ESID=1
ESMAC=02:00:00:00:20:01              # ES 시스템 MAC = 두 리프 bond 의 LACP actor system
MHMAC=02:00:00:00:20:10; MHIP=10.10.20.10   # hmh: leaf1·leaf2 에 한 줄씩 (bond0)
RMMAC=02:00:00:00:20:30; RMIP=10.10.20.30   # hrem: leaf3 에 한 줄
PORT=eth5                            # 리프 쪽 서버 포트 (eth3 = h, eth4 = v1·v3 가 이미 씀)
ST=$HERE/state

as_of()   { echo $((65010 + ${1#leaf})); }          # 현재 랩: leaf N = AS 6501N
vtep_of() { echo 10.255.1.${1#leaf}; }
vt() { local n=$1; shift; local a=(); for x in "$@"; do a+=(-c "$x"); done; dx "$n" vtysh "${a[@]}"; }

# 호스트 컨테이너 (alpine, 네트워크 없음). 도구는 WSL 쪽 것을 nsx 로 쓴다
host_up() {
  docker inspect "$(c "$1")" >/dev/null 2>&1 && return
  docker run -d --name "$(c "$1")" --hostname "$1" --network none --cap-add NET_ADMIN alpine:3 sleep infinity >/dev/null
}
# veth 한 줄: wire <리프> <리프포트> <호스트> <호스트포트>
wire() {
  nsx "$1" ip link show "$2" >/dev/null 2>&1 && return
  ip link add x18a type veth peer name x18b
  ip link set x18a netns "$(pid "$1")"; nsx "$1" ip link set x18a name "$2"
  ip link set x18b netns "$(pid "$3")"; nsx "$3" ip link set x18b name "$4"
}

# 상태 읽기 (watch.sh 가 50ms 마다, run.sh 가 대기할 때 쓴다)
l3() {   # l3 <leaf3 pid>: hmh MAC 의 원격 VTEP 들
  local P3=$1 f nh
  f=$(nsenter -t $P3 -n bridge fdb show dev $VX 2>/dev/null | grep -i "^$MHMAC" | grep -v master | head -1)
  [ -z "$f" ] && { echo "없음"; return; }
  nh=$(echo "$f" | grep -o 'nhid [0-9]*' | cut -d' ' -f2)
  if [ -z "$nh" ]; then echo "$f" | grep -o 'dst [0-9.]*'; return; fi
  nsenter -t $P3 -n ip nexthop show fdb 2>/dev/null | awk -v g=$nh '
    $3=="via"{via[$2]=$4} $1=="id"&&$2==g&&$3=="group"{grp=$4}
    END{ if(grp==""){print via[g]; exit} n=split(grp,a,"/"); s=""; for(i=1;i<=n;i++){split(a[i],b,","); s=s (i>1?"+":"") via[b[1]]} print s }'
}
mh() {   # mh <hmh pid>: bond0 두 줄 상태
  local PM=$1
  nsenter -t $PM -n cat /proc/net/bonding/bond0 2>/dev/null | awk '
    /^Active Aggregator Info/{a=1} a&&/Aggregator ID/{act=$3; a=0}
    /^Slave Interface/{s=$3} s&&/^MII Status/{m[s]=$3} s&&/Aggregator ID/{g[s]=$3}
    END{ for(x in m) out=out x ":" m[x] (g[x]==act?"/묶임":"/빠짐") " "; print out }' | tr ' ' '\n' | sort | tr '\n' ' '
}
pd() { local p=$1 x; for x in bond1 $PORT; do nsenter -t $p -n ip -d link show $x 2>/dev/null | grep -q 'protodown on' && echo -n "$x:protodown "; done; }

