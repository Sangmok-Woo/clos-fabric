#!/usr/bin/env bash
# 실험 15 — EVPN ESI-LAG: 서버를 리프 두 대에 한 줄씩 꽂았을 때 리프 한 대 장애를 몇 초에 견디는가
#   step0  사전 확인 (FRR 버전, bond/LACP, 패브릭)
#   step1  정상 상태: ES / Type-1 / Type-4 / DF, 흐름마다 지나는 길 (캡처 4곳)
#   A      leaf1 의 서버 포트(eth5) down
#   B      leaf1 전원 꺼짐: 모든 포트 동시 down (상대 쪽에서 캐리어가 사라짐)
#   C      leaf1 업링크(eth1·eth2)만 down, uplink 추적 없음
#   Cu     C 와 같고 evpn mh uplink 추적 켬
#   X      대조군: ES 없이 hmh 를 leaf1 에만 → B
# 회차마다: 탐침 시작 → PRE 초 → T0 주입 → FAULT 초 → T1 원복(= 시나리오 D) → POST 초.
# 1회차만 캡처 4곳(+스냅숏), 2·3회차는 숫자만.  먼저 setup.sh.  사용: run.sh [step0 step1 A B C Cu X]
set -u
. "$(dirname "$0")/common.sh"
OUT=$HERE/capture; mkdir -p "$OUT" "$HERE/img"
STEPS=${*:-step0 step1 A B C Cu X}
REPS=${REPS:-3}; PRE=3; FAULT=15; POST=20
exec > >(tee -a "$OUT/run-output.txt") 2>&1
now() { date +%s.%N; }

snap() {   # snap <파일>: 컨트롤 플레인 주소록
  { for n in leaf1 leaf2; do echo "### $n: show evpn es detail"; vt $n "show evpn es detail"; done
    echo "### leaf3: show evpn es";             vt leaf3 "show evpn es"
    echo "### leaf3: show evpn mac vni $VNI";   vt leaf3 "show evpn mac vni $VNI"
    echo "### leaf3: show bgp l2vpn evpn route type ead (Type-1)"; vt leaf3 "show bgp l2vpn evpn route type ead"
    echo "### leaf3: show bgp l2vpn evpn route type es (Type-4)";  vt leaf3 "show bgp l2vpn evpn route type es"
    echo "### leaf1: show bgp l2vpn evpn route type es (Type-4)";  vt leaf1 "show bgp l2vpn evpn route type es"
  } > "$1" 2>&1
}

caps_on() {   # caps_on <폴더>: 캡처 4곳 + leaf3 BGP
  local d=$1 c
  CAPDIR=$d
  SNAP=96  cap_start hmh-eth1   hmh   eth1 udp port 7001 or udp port 7002 or ether proto 0x8809
  SNAP=96  cap_start hmh-eth2   hmh   eth2 udp port 7001 or udp port 7002 or ether proto 0x8809
  SNAP=110 cap_start leaf3-eth1 leaf3 eth1 udp port 4789 or tcp port 179
  SNAP=110 cap_start leaf3-eth2 leaf3 eth2 udp port 4789 or tcp port 179
  cap_wait 1
}
caps_off() { cap_stop | sed 's/^/  /'; CAPDIR=$OUT; }

# 양쪽이 다 붙을 때까지 기다린다 (회차 사이)
settle() {
  local want=${1:-2} i s
  for i in $(seq 90); do
    # ES 를 다시 켠 직후엔 hmh MAC 이 ESI 없는 Type-2 로 남아 있다. hmh 가 말을 해야 새로 배운다 (README 함정 ①)
    nsx hmh ping -c 1 -W 1 $RMIP >/dev/null 2>&1
    s=$(l3 "$(pid leaf3)")
    est=$(vt leaf1 "show bgp summary json" 2>/dev/null | grep -c '"state":"Established"')
    if [ "$want" = 2 ]; then [[ "$s" == *+* ]] && [ "$est" -ge 2 ] && [ "$(mh "$(pid hmh)" | grep -o 묶임 | wc -l)" = 2 ] && break
    else [ -n "$s" ] && [ "$s" != 없음 ] && [ "$est" -ge 2 ] && break; fi
    sleep 1
  done
  sleep 5
  echo "  준비: leaf3→hmh=[$(l3 "$(pid leaf3)")] hmh=[$(mh "$(pid hmh)")] (${i}초)"
}

# 한 회차: once <시나리오> <회차> <주입함수> <원복함수>
once() {
  local scn=$1 rep=$2 inj=$3 rst=$4 d=$OUT/$1/r$2
  rm -rf "$d"; mkdir -p "$d"
  local dur=$((PRE + FAULT + POST)) P3 PM
  P3=$(pid leaf3); PM=$(pid hmh)
  [ "$rep" = 1 ] && { caps_on "$d"; snap "$d/snap-0-before.txt"; }
  rm -f "$d/stop"; "$HERE/watch.sh" "$d/events.txt" "$d/stop" &
  PIDS=()
  nsenter -t $PM -n python3 "$HERE/probe.py" recv 7001 "$d/to_mh.rx" $((dur + 2)) & PIDS+=($!)
  nsenter -t "$(pid hrem)" -n python3 "$HERE/probe.py" recv 7002 "$d/to_rm.rx" $((dur + 2)) & PIDS+=($!)
  sleep 0.5
  nsenter -t "$(pid hrem)" -n python3 "$HERE/probe.py" send $MHIP 7001 4 $dur 40000 "$d/to_mh.tx" & PIDS+=($!)
  nsenter -t $PM -n python3 "$HERE/probe.py" send $RMIP 7002 4 $dur 41000 "$d/to_rm.tx" & PIDS+=($!)
  nsenter -t "$(pid hrem)" -n ping -D -O -i 0.01 -W 1 -w $dur $MHIP > "$d/ping-rm2mh.txt" 2>&1 & PIDS+=($!)
  nsenter -t $PM -n ping -D -O -i 0.01 -W 1 -w $dur $RMIP > "$d/ping-mh2rm.txt" 2>&1 & PIDS+=($!)
  sleep $PRE
  local T0 T1; T0=$(now); $inj
  sleep $((FAULT - 2)); [ "$rep" = 1 ] && snap "$d/snap-1-fault.txt"; sleep 2
  T1=$(now); $rst
  echo "$T0 $T1" > "$d/times"
  wait_probes
  touch "$d/stop"; sleep 0.2
  [ "$rep" = 1 ] && { snap "$d/snap-2-after.txt"; caps_off; }
  echo "  ── $scn 회차 $rep"
  python3 "$HERE/analyze.py" "$d" "$scn" "$rep" || return 1   # 실패하면 원자료를 남긴다
  if [ "$rep" = 1 ]; then
    python3 "$HERE/pcapflow.py" timeline "$d" "$T0" "$T1" "실험 15 — 시나리오 $scn (1회차)" "$HERE/img/$scn-timeline.svg"
    python3 "$HERE/pcapflow.py" trim "$d" "$T0" "$T1"; rm -f "$d"/*.rx "$d/stop"
  else
    rm -f "$d"/*.rx "$d"/ping-*.txt   # 2·3회차 원자료는 숫자만 남기고 버린다
  fi
}
wait_probes() { wait "${PIDS[@]}" 2>/dev/null; }

# ── 주입 / 원복
A_inj()  { nsx leaf1 ip link set $PORT down; }
A_rst()  { nsx leaf1 ip link set $PORT up; }
B_inj()  { printf 'link set %s down\n' eth1 eth2 eth3 eth4 $PORT | nsx leaf1 ip -batch -; }
B_rst()  { printf 'link set %s up\n'   eth1 eth2 eth3 eth4 $PORT | nsx leaf1 ip -batch -; }
C_inj()  { printf 'link set %s down\n' eth1 eth2 | nsx leaf1 ip -batch -; }
C_rst()  { printf 'link set %s up\n'   eth1 eth2 | nsx leaf1 ip -batch -; }

scenario() {   # scenario <이름> <주입> <원복> <설명>
  say "$1 — $4"
  local r; for r in $(seq $REPS); do settle ${WANT:-2}; once "$1" $r "$2" "$3"; done
}

step0() {
  say "Step 0 — 사전 확인"
  echo "  FRR: $(vt leaf1 'show version' | head -1)"
  echo "  커널: $(uname -r), bonding: $(lsmod | grep -c '^bonding')"
  vt leaf1 "show bgp summary" | grep -E '^(10\.|Neighbor|spine)' | sed 's/^/  leaf1  /'
  echo "  EVPN-MH: $(vt leaf1 'show evpn es' | grep -c '^03:') 개 ES (leaf1)"
  nsenter -t "$(pid hmh)" -n cat /proc/net/bonding/bond0 | grep -E 'Bonding Mode|LACP rate|Transmit Hash|Slave Interface|MII Status|Aggregator ID|Partner Mac|system mac' | sed 's/^/  hmh  /'
  echo "  hrem → hmh: $(nsx hrem ping -c 3 -i 0.2 -W 1 $MHIP | tail -2 | head -1)"
  echo "  v1 → v3 (기존 VNI 10010): $(dx v1 ping -c 2 -W 1 10.10.10.33 | grep -o '[0-9]* packets received')"
}

step1() {
  say "Step 1 — 정상 상태"
  local d=$OUT/step1; rm -rf "$d"; mkdir -p "$d"
  snap "$d/snap.txt"
  grep -A12 '### leaf1: show evpn es detail' "$d/snap.txt" | grep -E 'ESI|DF status|DF pref|VTEPs|10\.255' | sed 's/^/  leaf1  /'
  grep -A12 '### leaf2: show evpn es detail' "$d/snap.txt" | grep -E 'DF status|10\.255' | sed 's/^/  leaf2  /'
  grep -A6 '### leaf3: show evpn es$' "$d/snap.txt" | grep '^03' | sed 's/^/  leaf3 ES  /'
  grep -A8 "show evpn mac vni" "$d/snap.txt" | grep -i "$MHMAC" | sed 's/^/  leaf3 MAC /'
  echo "  Type-1: $(grep -c '^ *\*.*\[1\]' "$d/snap.txt") 줄, Type-4: $(grep -c '^ *\*.*\[4\]' "$d/snap.txt") 줄 (자세히는 capture/step1/snap.txt)"
  # 흐름 8개를 3초 흘려 각 흐름이 어느 리프·스파인을 지나는지
  caps_on "$d"
  nsenter -t "$(pid hmh)" -n python3 "$HERE/probe.py" recv 7001 "$d/to_mh.rx" 5 &
  nsenter -t "$(pid hrem)" -n python3 "$HERE/probe.py" recv 7002 "$d/to_rm.rx" 5 &
  sleep 0.5
  nsenter -t "$(pid hrem)" -n python3 "$HERE/probe.py" send $MHIP 7001 8 3 40000 "$d/to_mh.tx" &
  nsenter -t "$(pid hmh)" -n python3 "$HERE/probe.py" send $RMIP 7002 8 3 41000 "$d/to_rm.tx" &
  sleep 6
  caps_off
  python3 "$HERE/pcapflow.py" flows "$d"
  rm -f "$d"/*.rx
}

for s in $STEPS; do
  case $s in
    step0|step1) $s ;;
    A)  scenario A  A_inj A_rst "leaf1 서버 포트 down" ;;
    B)  scenario B  B_inj B_rst "leaf1 전원 꺼짐 (모든 포트 동시 down)" ;;
    C)  scenario C  C_inj C_rst "leaf1 업링크만 down, uplink 추적 없음" ;;
    Cu) "$HERE/setup.sh" uplink on; scenario Cu C_inj C_rst "leaf1 업링크만 down, uplink 추적 켬"; "$HERE/setup.sh" uplink off ;;
    X)  "$HERE/setup.sh" single; WANT=1 scenario X B_inj B_rst "대조군: ES 없이 leaf1 에만, leaf1 전원 꺼짐"; "$HERE/setup.sh" esi >/dev/null ;;
  esac
done
