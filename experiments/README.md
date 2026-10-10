# experiments — 장애 시나리오

베이스 패브릭(스파인 2 + 리프 4, eBGP 언더레이 + VXLAN/EVPN)은 고정해 두고, 그 위에서 장애를 하나씩 재현한다.
실험 하나가 디렉터리 하나다. 장마다 장애 지점 앞뒤를 동시에 캡처하고, Wireshark 화면·원본 pcap·결론을 함께 둔다.

## 목록

| # | 실험 | 주입하는 장애 | 상태 |
|---|---|---|---|
| 01 | [숨은 MTU 결함 + 스파인 장애](01-hidden-mtu-meets-spine-failure/README.md) | spine2 포트 MTU 1500인 채로 spine1이 조용히 죽음. 같은 장애로 모니터링 1차→3차 비교 | 완료 |
| 02 | [물리 계층 불량](02-physical-corruption/README.md) | tc netem으로 비트 깨짐 4%, 몰려오는 손실 | 완료 |
| 03 | [L2 루프·브로드캐스트 스톰](03-broadcast-storm/README.md) | VXLAN 브리지에 veth 양 끝을 꽂아 고리 | 완료 |
| 04 | [DNS 장애](04-dns-failure/README.md) | 잘못된 레코드 / DNS 프로세스 중지 / 53번 DROP | 완료 |
| 05 | [ECMP 분산](05-ecmp-hash/README.md) | 해시 정책 0/1/3에서 흐름 40개의 링크별 분산, 같은 흐름을 다시 보내기 | 완료 |
| 06 | [링크 다운 수렴](06-link-down-convergence/README.md) | 지금 쓰는 스파인 링크를 내림, 인터페이스 다운 감지 | 완료 |
| 07 | [스파인 무응답과 BFD](07-spine-freeze-bfd/README.md) | 스파인 freeze, BGP 타이머 vs BFD 300ms×3 | 완료 |
| 08 | [패킷의 일생: EVPN-VXLAN vs 순수 L3](08-packet-life-evpn/README.md) | 주소록(Type-2/3) → 캡슐화 → 스파인 통과 → 도착을 따라가고, L2 확장·이사·멀티테넌시·ARP 억제와 그 비용을 순수 L3와 비교 | 완료 |
| 09 | 세션 테이블 고갈 | NAT 포트 범위를 좁히고 연결 폭주 → 새 연결만 실패 | 예정 |
| 10 | [마이크로버스트](10-microburst/README.md) | 평균 90Mbit/s를 고르게 / 300개씩 몰아서 100Mbit·버퍼 64KB 포트로 | 완료 |
| 11 | 비대칭 라우팅 + 상태 기반 방화벽 | 리턴 경로만 다르게 → 방화벽이 응답을 버림 | 예정 |
| 12 | [RoCEv2: 깔고, 보고, 튜닝하기](12-roce/README.md) | Soft-RoCE 를 커널에 올려 패브릭 위로. 손실 1%, 3:1 인캐스트(버퍼·속도 제한·송신 창), QP 수와 ECMP 해시 | 완료 |
| 14 | [ACL vs 방화벽](14-acl-vs-firewall/README.md) | 같은 정책을 stateless/stateful에. 위조 ACK·UDP 왕복·비대칭 라우팅·conntrack 고갈 | 완료 |
| 15 | [EVPN 패브릭 위의 5G 코어](15-5g-core-evpn/README.md) | Open5GS CP/UP 분리, GTP-U in VXLAN의 MTU 두 겹, 구간별 VRF, N2·N4 차단·UPF 정지, AMF 파드 삭제 | 기획 |
| 16 | [ECMP + 방화벽 두 대](16-ecmp-fw-sync/README.md) | 갈 때·올 때 다른 FW로 갈리는 ECMP. 해시 5종 비교, 대칭 해시 vs conntrackd(+RTT별 경주) | 완료 |

01~04와 10은 장애를 넣고 패킷으로 읽는 장, 08은 오버레이가 하는 일을 패킷으로 따라간 장, 05~07은 패브릭의 기본 동작(분산·수렴·BFD)을 패킷으로 다시 잰 장이다.
05~07은 원래 [docs/EXPERIMENTS.md](../docs/EXPERIMENTS.md) §1·§2에 있던 측정을 캡처와 함께 다시 한 것이다.

[_archive/](_archive/)에는 이전 실험(옛 01번 HTTP 전송 + MTU 장애)을 보관한다.

## 실행 준비

```bash
cd /root/labs/clos-fabric/monitoring && ./up.sh        # 패브릭 + 관측 스택
cd .. && sleep 20 && ./scripts/evpn-apply.sh           # VXLAN/EVPN
experiments/_tools/prep-hosts.sh                       # 서버에 curl·httpd·iperf3·dnsmasq
experiments/NN-이름/run.sh                             # 장마다 주입 → 캡처 → 트래픽 → 원복
```

WSL에서는 랩을 쓰는 동안 배포판에 살아 있는 프로세스를 하나 붙잡아 둬야 한다. 배포판이 꺼지면 dockerd가 재시작되면서 랩의 veth가 전부 사라진다.

## 공통 도구 (`_tools/`)

| 파일 | 하는 일 |
|---|---|
| `lab.sh` | 장마다 source 하는 함수 모음. 노드 netns 에서 호스트 도구 실행(`nsx`), 캡처 시작·종료(`cap_start`/`cap_stop`), 서버 패키지 설치(`apk_add`) |
| `prep-hosts.sh` | 서버 6대에 curl·httpd·iperf3·dnsmasq 설치 (랩을 새로 띄울 때 한 번) |
| `timeline.sh` | 수렴 장(06·07)의 시간 계산: 장애 시각 T0 기준 ping 공백, 응답 없는 요청 수, BGP·BFD 메시지 타임라인 |
| `ws-shot.ps1` | (윈도우) pcap 을 Wireshark 로 열어 창을 PNG 로 저장. `-Col "제목=필드"`로 열 추가, `-Crop N`으로 패킷 목록만 |
| `detail.sh` | (윈도우) 패킷 하나의 상세 트리를 텍스트로 (tshark -V) |
| `wireshark-profile/` | 스크린샷용 Wireshark 프로필: 기본 열, 체크섬 검사 켬 |

## 규칙

1. **베이스를 바꾸지 않는다.** `clos.clab.yml`과 `configs/`는 그대로 둔다. 실험에 필요한 값은 `run.sh`가 실행 중에 바꾼다.
2. **바꾼 값은 되돌린다.** 원래 값을 `state/`에 적어 두고 `run.sh` 끝에서 원복한다. 중간에 멈추면 `restore.sh`로 되돌린다.
3. **디렉터리 하나로 닫는다.** 스크립트·문서·캡처가 전부 그 안에 있다. 공통 함수는 `_tools/lab.sh`에서만 가져온다.
4. **pcap은 잘라서 올린다.** 패킷당 앞 128~256바이트만 남기고(헤더 흐름은 그대로 보인다), 수십만 개짜리 캡처는 앞부분만 남긴다. `state/`는 올리지 않는다.

## 장의 모양

```
experiments/NN-이름/
├── README.md      장애 구성 → 실행 → 숫자 → 패킷 흐름(Wireshark 화면) → 결론
├── run.sh         주입 → 캡처 → 트래픽 → 원복. 출력은 capture/run-output.txt 로도 남긴다
├── restore.sh     run.sh 가 중간에 멈췄을 때 원복
├── capture/       원본 pcap, 실행 기록
└── img/           Wireshark 화면 (ws-shot.ps1 로 저장)
```

결론은 표가 아니라 두세 문단의 글로 쓴다. 무엇을 넣었고 겉으로 어떻게 보였는지, 숫자와 이유, 다음에 같은 증상을 만나면 어디부터 볼지.

## 새 실험 추가

```bash
cp -r experiments/_template experiments/NN-이름
```

1. `run.sh`에 주입·캡처·트래픽·원복을 쓰고, `restore.sh`에 되돌리는 명령을 적는다
2. 돌려서 캡처를 얻고, `_tools/ws-shot.ps1`로 Wireshark 화면을 저장한다
3. `README.md`를 채운다
4. 위 목록 표와 [메인 README](../README.md#장애-시나리오)의 표에 한 줄씩 더하고, [CHANGELOG](../CHANGELOG.md)에 적는다
