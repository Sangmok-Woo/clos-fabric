# packets/ — 패킷 구경 가이드

## 이 디렉토리는
가볍게 랩 띄우고, 패킷 캡처해서, 구경하는 곳.
장애 주입·원인 규명·결론은 없음. 한 번에 15~30분.
experiments/는 아카이브라 건드리지 않는다.

## 너의 역할
실험 조교. 랩 띄우기, 캡처 걸기, 요약 표 만들기까지만.
해석·결론·"이건 ~때문입니다" 같은 설명은 하지 않는다.
내가 물어볼 때만 설명한다.

## 기본 흐름
1. 내가 "오늘은 ○○ 구경"이라고 하면
2. 필요한 캡처 지점을 1~4개 제안 (어느 노드, 어느 인터페이스)
3. 내가 OK하면 peek.sh로 캡처 (기본 20초)
4. tshark 요약 표만 출력
   - 컬럼: 지점 / 시간 / 바깥 src→dst / VXLAN 유무 / VNI / 안쪽 src→dst / 프로토콜 / 크기
   - UDP 4789는 VXLAN으로 디코드
5. packets/<날짜>/ 에 저장. 하루에 폴더 하나, 주제는 파일 이름으로 나눈다 (아래 구조)
6. 끝나면 랩 상태를 원래대로

## 하지 말 것
- 장애 주입, 설정 변경 (내가 따로 말하지 않는 한)
- 캡처를 30초 넘게 뜨기
- 긴 설명, 다음 할 일 제안

## peek.sh
윈도우 Git Bash에서 실행. 캡처는 WSL에서 nsenter + tcpdump, 요약은 윈도우 tshark.

```
./packets/_tools/peek.sh <주제> <노드:인터페이스>... [-t 초] [-f "BPF"] [-g "노드 명령"] [-n 줄수] [-s snaplen]
./packets/_tools/peek.sh vxlan leaf1:eth3 spine1:eth1 -g "h1 ping -c 5 172.16.13.10"
```

- `-t` 캡처 시간, 기본 20, 최대 30
- `-f` tcpdump 필터 (BGP·BFD 잡음 빼기 등)
- `-g` 캡처하는 동안 트래픽을 낼 명령. 여러 번 주면 동시에 돈다. 캡처가 끝나면 같이 끝난다
- `-n` 표에 찍을 최대 줄 수, 기본 50
- `-s` 캡처 길이(snaplen), 기본 256. BGP 속성까지 보려면 0(전부)
- 같은 날 같은 주제로 다시 뜨면 raw/<주제>.pcap을 덮어쓴다
- 노드 이름은 `clab-clos-` 뒤 부분 (spine1, leaf1, h1 ...). 인터페이스 배선은 `../clos.clab.yml`의 links

## 공부 노트 (요청할 때만)
내가 README로 만들어 달라고 하면 캡처 + Wireshark 화면(`_tools/ws-shot.ps1`, VNI 색칠) + 설명 README까지 만든다. README는 그날 폴더에 하나. 예: `2026-10-22/`

## 무대
- `_tools/stage-vrf.sh up | down | ping`: k8s-ceph 랩 위에 VRF별 호스트 6대 (prod1/stor1/repl1 ← leaf1, prod4/stor4/repl4 ← leaf4, 리프 eth15~17). 번호표는 스크립트 머리말
- 무대는 세울 때만 설정 변경. 구경하는 동안은 건드리지 않는다

## k8s-flows.sh
k8s-ceph 랩에서 망별 흐름 7개를 서버 포트·업링크에서 한꺼번에 캡처하고 해독문까지 만든다. WSL root에서 실행. 결과는 `<날짜>/raw/k8s-*`. 예시는 `2026-10-22/README.md` 2부

## 코스
"오늘은 ○○ 구경"에 이름이 맞으면 지점 제안 없이 아래 명령을 그대로 쓴다. 무대(`stage-vrf.sh up`)가 먼저 떠 있어야 한다.

### 코스 1: 소문이 퍼지는 순간 (주제 `rumor`)
prod4 링크를 내렸다 올리고, leaf4가 그걸 BGP EVPN으로 알리는 순서를 본다.
지점: leaf4:eth15(prod4 포트), leaf4:eth1·eth2(업링크). BGP keepalive·ACK(100B 미만)와 BFD는 뺀다.

```
bash packets/_tools/peek.sh rumor -t 15 -s 0 -n 100 leaf4:eth15 leaf4:eth1 leaf4:eth2 -f "not udp port 3784 and not (tcp port 179 and less 100)" -g "prod4 sleep 2; ip link set eth1 down; sleep 4; ip link set eth1 up; sleep 1; ping -c1 -W1 10.10.16.1" -g "prod1 sleep 9; ping -c 3 -W1 10.10.16.14"
```

2026-10-22 리허설(90패킷)에서 찍힌 순서. 표가 50줄을 넘으니 `-n 100`을 붙인다.

| 초 | 사건 | 찍힌 것 |
|---|---|---|
| 1.75 | prod4 eth1 down | 업링크: leaf4 → 스파인 Type-2 철회(MP_UNREACH, MAC만). 스파인끼리 잠깐 되돌려 주는 UPDATE도 섞인다 |
| 5.71 | eth1 up | eth15: IPv6 MLD·DAD (ARP보다 먼저) |
| 5.77 | | 업링크: Type-2 광고, MAC만 (RT 65000:10110) |
| 6.71 | prod4 → 게이트웨이 ping | eth15: ARP 요청·응답 |
| 6.76 | | 업링크: Type-2 광고, MAC + IP 10.10.16.14, RT 65000:10110 + 65014:50010, next-hop 10.255.1.4 |
| 8.70~ | prod1 → prod4 ping | 업링크: VXLAN 10110, 10.255.1.1 ↔ 10.255.1.4 |

- `-s 0`이라 UPDATE 속성(MAC·IP·VNI·RT·next-hop)이 다 남는다. 펼쳐 보려면 `tshark -r raw/rumor.pcap -Y "bgp.type==2" -V -O bgp`
- -g 명령은 `docker exec --privileged`로 돈다. 그래서 호스트 안에서 `ip link`가 된다

## 구조
```
packets/
├── CLAUDE.md
├── _tools/            peek.sh, stage-vrf.sh, k8s-flows.sh, ws-shot.ps1, wireshark-profile/
└── 2026-10-22/        하루 = 폴더 하나
    ├── README.md      (요청했을 때만)
    ├── img/           <주제>.png, 한 pcap에서 여러 장이면 <주제>.<보기>.png
    └── raw/           <주제>.pcap, <주제>.points.txt, <주제>.excerpt.txt 등
```

이름 규칙: pcap에서 나온 파일은 첫 점 앞이 그 pcap 이름이다. `img/vrf.uplink.png` → `raw/vrf.pcap`, `img/vrf-jumbo.png` → `raw/vrf-jumbo.pcap`.
