# EVPN/VXLAN 패킷 캡처

`scripts/capture.sh` 로 뜬 pcap들. Wireshark로 열면 VXLAN(UDP 4789)과
BGP EVPN NLRI가 자동으로 해석된다. (tcpdump는 EVPN NLRI를 못 읽는다 —
`no AFI 25 / SAFI 70 decoder` 가 뜨면 그게 그 뜻)

## 01-vxlan-data.pcap — 데이터 패킷 (leaf1:eth2)
v1(10.10.10.11) → v3(10.10.10.33) 통신. 랙이 다른데 같은 서브넷이다.

봐야 할 것:
- **이중 헤더**: 바깥 `10.255.1.1 → 10.255.1.3` (리프 루프백=VTEP끼리) UDP 4789,
  그 안에 원래 이더넷 프레임 `aa:c1:ab:87:24:ad → aa:c1:ab:19:61:e8` 가 통째로 들어있다.
  택배 상자(바깥) 안에 원래 편지(안쪽)가 그대로 든 모양.
- **VNI 10010**: 상자에 붙은 방 번호. 같은 VNI끼리만 같은 L2로 본다.
- **바깥 UDP 출발포트가 흐름마다 다르다** (ARP는 33503, ICMP는 42615).
  스파인이 이 값으로 해시해서 ECMP 분산을 한다. 안쪽 내용은 안 본다.
- **BUM**: 없는 호스트(10.10.10.99) ARP도 브로드캐스트인데 멀티캐스트가 아니라
  10.255.1.3 **유니캐스트로** 나간다 = head-end replication.
  EVPN Type-3 경로로 "이 VNI에 leaf3도 있다"를 미리 알기 때문.

Wireshark 필터: `vxlan` / `vxlan.vni == 10010` / `icmp`

## 02-bgp-evpn-type2.pcap — MAC 광고 (leaf1:eth2)
leaf3의 서버 포트를 내렸다 올려서 Type-2 철회 → 재광고를 유발한 캡처.

봐야 할 것:
- **MP_UNREACH_NLRI** = MAC 철회, **MP_REACH_NLRI** = MAC 광고
- **Route Type 2 (MAC/IP Advertisement)**: v3의 MAC + VNI 10010 + 넥스트홉 10.255.1.3
- 넥스트홉이 스파인 주소가 아니라 **leaf3 루프백 그대로**다.
  스파인에 `attribute-unchanged next-hop` 를 넣은 이유 — 바꾸면 터널이 스파인으로
  꽂혀서 깨진다.

Wireshark 필터: `bgp.evpn.nlri.rt == 2`

## 03-bgp-evpn-session-up.pcap — 세션 재협상 (leaf1:eth1)
`evpn-apply.sh` 실행 중 캡처. 세션이 끊겼다 붙으면서 OPEN 메시지에
**l2vpn-evpn capability** 가 새로 실리는 구간이 들어있다.
(주소군을 나중에 켜면 soft clear로는 안 되고 세션을 끊었다 붙여야 하는 이유)

Wireshark 필터: `bgp.type == 1` (OPEN)

## 다시 뜨려면
```
./scripts/capture.sh leaf1 eth2 10 내파일이름 'udp port 4789'
```
VXLAN은 ECMP 때문에 업링크 **한쪽으로만** 간다. eth2가 비면 eth1을 잡아볼 것.

---

## 열기 — `open.cmd`

컬럼과 필터를 미리 박아둔 Wireshark 프로파일로 연다.

```
open.cmd                    # 01-vxlan-data.pcap, VXLAN 보기
open.cmd bgp                # 02-bgp-evpn-type2.pcap, EVPN 경로 보기
open.cmd vxlan 내파일.pcap
open.cmd bgp   내파일.pcap
```

프로파일은 `%APPDATA%\Wireshark\profiles\` 의 `EVPN-VXLAN` / `EVPN-BGP`.
Wireshark 오른쪽 아래 프로파일 이름을 눌러 수동으로도 바꿀 수 있다.

- **EVPN-VXLAN** — 바깥 IP / UDP 출발포트 / VNI / 안쪽 IP / 안쪽 MAC 을 한 줄에 펼친다.
  `%Cus:ip.src:1:R` 이 바깥, `:2:` 가 안쪽. (`:0:` 은 "전부"라 둘이 쉼표로 붙어 나온다)
- **EVPN-BGP** — 경로타입 / RD / MAC / 라벨 / 넥스트홉.

### 함정
- `Wireshark.exe -o "gui.column.format:..."` 를 .cmd 안에서 쓰면 **따옴표가 깨져서
  Wireshark가 조용히 죽는다.** 프로파일(`-C 이름`)로 넘기는 게 안전하다.
- BGP 보기의 `Label` 컬럼은 **625** 로 나오는데 VNI 10010 이 맞다.
  Wireshark가 MPLS 라벨로 읽어 4비트 밀어버린 값(10010 >> 4 = 625).
  진짜 VNI 는 패킷 상세의 NLRI 바이트나 데이터플레인 캡처에서 확인할 것.

---

## 실시간으로 보기 — `live.cmd` + `traffic.sh`

패킷은 WSL 안 컨테이너에서 돌고 Wireshark는 윈도우에 있어서, 둘을 파이프로 잇는다.
WSL 쪽 tcpdump가 pcap을 표준출력으로 흘리고(`scripts/stream.sh`),
윈도우 Wireshark가 그걸 표준입력으로 받는다(`-k -i -`).

### 1) 트래픽 켜기 (WSL 쪽)
```
wsl -d Ubuntu -u root -e bash -lc "cd /root/labs/clos-fabric && ./scripts/traffic.sh"
```
- v1→v3 (VXLAN 캡슐화됨) + h1→h2/h3/h4 (평범한 라우팅) 을 계속 보낸다
- 매번 새 ping 프로세스라 ICMP id가 달라지고, 그래서 바깥 UDP 포트도 달라진다
  → 스파인 두 대로 번갈아 흩어지는 게 보인다
- 10회마다 ARP 재해석, 17회마다 없는 주소로 ARP(브로드캐스트 구경)
- 백그라운드로 돌리려면 `(setsid nohup ./scripts/traffic.sh 1 >/tmp/traffic.log 2>&1 &)`
- 끄기: `pkill -f traffic.sh`

### 2) 캡처 창 띄우기 (윈도우 쪽)
```
live.cmd          VXLAN 트래픽 (EVPN-VXLAN 컬럼)
live.cmd bgp      BGP EVPN 경로 (EVPN-BGP 컬럼)
live.cmd all      전부
live.cmd vxlan leaf3
```
Wireshark를 닫으면 캡처가 멈춘다.

### 함정
- **.cmd 파일에 한글을 넣으면 안 된다.** cp949에서 깨져서 배치 파서가
  엉뚱한 줄에서 죽는다(`'""'은(는) 내부 명령이 아닙니다`). 주석까지 영문으로.
- `-i any` 로 잡고 `udp port 4789` 로 거르면 업링크 두 개(eth1/eth2)를 한 번에 본다.
  대신 바깥 이더넷 헤더는 안 남는다(Linux cooked capture). 바깥 MAC까지 봐야 하면
  `live.cmd vxlan leaf1` 대신 `scripts/capture.sh leaf1 eth2 ...` 로 물리 인터페이스를 잡을 것.
- WSL 배포판이 꺼지면 dockerd가 재시작되면서 **랩의 veth가 전부 사라진다.**
  캡처가 갑자기 조용해지면 랩부터 확인: `docker exec clab-clos-leaf1 ip -br link`
  (eth0 하나만 있으면 죽은 것 → `containerlab deploy` + `scripts/evpn-apply.sh` 재실행)
