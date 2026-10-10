# 변경 기록

패치노트처럼 **무엇이 바뀌었는지**를 쌓는다. 최신이 위.
설계 근거는 [docs/DESIGN.md](docs/DESIGN.md), 측정 결과는 [experiments/](experiments/README.md)에 적는다.

## 쓰는 법

- 작업은 **버전(마일스톤)** 으로 묶고, 제목에 그 작업을 한 실제 날짜(범위)를 적는다
- 버전 안의 분류는 다섯 개: **추가** · **변경** · **삭제** · **검증**(랩에서 실측) · **결정**(미결정 항목을 닫음). 항목이 많은 버전은 주제별로 먼저 나눈다
- 재배포가 필요한 변경에는 **⚠ 재배포**를 붙인다 — 받아 쓰는 쪽이 `./scripts/deploy.sh redeploy`를 해야 하는지 바로 알 수 있게
- AS·주소·포트 같은 **값이 바뀌면 `이전 → 이후`**를 적는다
- 실험 번호는 지금 번호로 적는다. 번호가 바뀐 이력은 해당 버전의 변경 항목에 남긴다

| 버전 | 기간 | 한 줄 |
|---|---|---|
| [v0.12](#v012--ecmp--방화벽-두-대-2026-10-10) | 2026-10-10 | 실험 16 ECMP + 방화벽 두 대: 대칭 해시 vs conntrackd |
| [v0.11](#v011--5g-코어-기획-2026-10-10) | 2026-10-10 | 실험 15 EVPN 패브릭 위의 5G 코어 (기획만) |
| [v0.10](#v010--acl-vs-방화벽-2026-10-10) | 2026-10-10 | 실험 14 ACL(stateless) vs 방화벽(stateful) |
| [v0.9](#v09--ansible-2026-10-09) | 2026-10-09 | 상태를 만드는 셸 스크립트 8개를 Ansible playbook으로 |
| [v0.8](#v08--rocev2-2026-10-09) | 2026-10-09 | 실험 12 RoCEv2, 모니터링 4차(RoCE NIC 카운터) |
| [v0.7](#v07--패킷의-일생-2026-10-05) | 2026-10-05 | 실험 08 패킷의 일생: EVPN-VXLAN vs 순수 L3 |
| [v0.6](#v06--마이크로버스트-2026-10-04) | 2026-10-04 | 실험 10 마이크로버스트 |
| [v0.5](#v05--패킷-캡처로-읽는-장애-2026-10-02--10-03) | 2026-10-02 ~ 10-03 | 장애 7개 장을 패킷 캡처·Wireshark 화면으로, 모니터링 2·3차 |
| [v0.4](#v04--장애-시나리오-구조-2026-09-30) | 2026-09-30 | 실험을 디렉터리 단위로 쌓는 구조 |
| [v0.3](#v03--관측-2026-09-20) | 2026-09-20 | Prometheus + Grafana, 감지 시간 실측 |
| [v0.2](#v02--확장-검증과-운영-문서-2026-08-25--09-10) | 2026-08-25 ~ 09-10 | listen range 기각, BGP unnumbered 채택, 운영 문서 |
| [v0.1](#v01--랩-초기-구성-2026-08-10) | 2026-08-10 | 스파인 2 + 리프 4 패브릭 |

---

## v0.12 — ECMP + 방화벽 두 대 (2026-10-10)

### 추가
- `experiments/16-ecmp-fw-sync/` — 랩 `fwecmp`(h1·leafA·fw1·fw2·leafB·srv + FW 간 동기화 링크), 흐름별 갈 때/올 때 FW를 nft 집합으로 기록하는 `obs.nft`, 회차별 흐름표(`capture/*.tsv`)
- 이미지 `fwlab:2` = `fwlab:1` + conntrackd

### 검증
- 비대칭 해시(출발IP+포트)에서 FW 켜면 실패 49% = 비대칭 흐름 49/49, 필터 없을 땐 비대칭 54개에도 0%
- 해시 방식이 다르면 50%, 해시가 대칭이어도 넥스트홉 순서가 다르면 100%
- 리눅스 `fib_multipath_hash_policy=1`은 skb에 이미 있는 해시(소켓 txhash, 재전송 때 새로 뽑힘)를 써서 대칭이 아니다 — SYN이 두 FW를 다 지난 흐름 29개, 실패 22%
- 대칭 해시(policy 3, fields 0x37, 같은 넥스트홉 순서) 실패 0%·분산 42:58. L3끼리는 0%지만 분산 0:100
- conntrackd(FTFW, DisableExternalCache on) 실패 2%, 단 RTT 0.1ms에선 비대칭 흐름 전부 connect +1초(경주 패배). 양쪽 10ms 지연이면 지연 0

### 결정
- 실험 14 Phase 5와 이어지는 비대칭 문제는 대칭 해시를 1순위 해법으로 기록. conntrackd는 RTT가 동기화 지연보다 긴 경계용

## v0.11 — 5G 코어 기획 (2026-10-10)

### 추가
- `experiments/15-5g-core-evpn/README.md` — Open5GS·UERANSIM을 리프 4개에 CP/UP 분리로 올리는 실험의 기획(Phase 0~7, 비유표, 빈 주소·VRF 계획표, 설정 스켈레톤, 관찰 기록표). 토폴로지·스크립트는 아직 없음

### 검증
- WSL 커널 6.6.114.1: `CONFIG_IP_SCTP=m`(modprobe 성공), `CONFIG_TUN=m`, `CONFIG_VXLAN=y`, `CONFIG_NET_VRF=m`, 커널 GTP 없음(사용자 공간 UPF라 무관)

### 결정
- Phase 순서 5 → 4: VXLAN 안의 GTP-U를 보려면 N3가 먼저 L3VNI를 타야 한다
- Phase 7의 kind는 Docker Desktop의 `shop`이 아니라 WSL dockerd 위에 새로 — containerlab과 같은 도커여야 leaf2에 붙는다

## v0.10 — ACL vs 방화벽 (2026-10-10)

### 추가
- `experiments/14-acl-vs-firewall/` — 베이스와 따로 뜨는 작은 랩 `fwacl`(h1·leaf1·acl·fw·serverA·serverB, 우회 링크 2개), 단계 실행기 `run.sh`(Phase 0~6), 노트·결과표
- 이미지 `fwlab:1`(ubuntu 24.04 + nftables·conntrack·hping3·dnsmasq) — alpine에는 hping3가 없어서

### 검증
- 관리망(clab)에 붙인 컨테이너에는 도커가 DNS용 NAT 규칙을 깔아 conntrack이 켜진다 → 전 노드 `network-mode: none`
- `nf_conntrack_max`는 컨테이너(비 init netns) 안에서 읽기 전용 → Phase 6은 WSL 호스트 값을 바꿔야 한다
- 1회차 `run.sh all`: 위조 ACK ACL 통과 3/3·FW 0/3, UDP `sport 53` 구멍으로 위조 2/2 통과, 비대칭 시 FW만 ping OK·curl 실패(SYN_SENT 고착), max 40에서 FW 39/60·기존 연결 유지·`table full` 로그
- 비대칭 경로에선 서버 → h1 선제 접속이 ACL·FW 둘 다 우회로로 통과 — 장애이자 정책 우회

## v0.9 — Ansible (2026-10-09)

### 추가
- `ansible/` — 인벤토리(fabric = spines·leaves, servers, control), group_vars·host_vars(AS·루프백·서버망·링크), 실행기 `run.sh`
- playbook 8개: `deploy`·`check`·`bfd`·`evpn`·`prep-hosts`·`monitoring`·`listen-range`·`unnumbered`. 원래 셸 스크립트는 그대로 둠
- `ansible/README.md` — 바꾼 것·셸로 남긴 것과 근거, 셸 값이 인벤토리·변수로 옮겨 간 자리

### 검증
- `bfd`·`evpn`·`prep-hosts` 두 번째 실행 changed=0, `bfd --check`가 바뀔 장비 6대를 보고
- `deploy -e lab_state=redeploy` → `check` 수렴 대기 후 통과, 이어서 `evpn`으로 v1 → v3 통신
- `listen-range`·`unnumbered` 실행 후 `always` 원복, `check` 통과
- `monitoring` 올리기(베이스 내림 → 관측 토폴로지 16노드 → Grafana·Prometheus 응답) → 다시 실행 changed=0 → `mon_state=down` → `deploy`로 베이스 복귀

### 결정
- 캡처·트래픽·시간 측정(`capture`·`stream`·`traffic`·`failover`·`ecmp-hash`·`detect-time`·`timeline`), `day.sh`, 실험 `run.sh`는 셸로 유지. Ansible 작업당 지연이 측정값에 섞인다
- 스파인 EVPN 설정에서 `neighbor FABRIC attribute-unchanged next-hop`을 원하는 상태에서 뺌. FRR 10.2가 running-config에 보이지 않아 매번 재적용 + 세션 재기동을 일으켰고, 빼고 새로 띄운 랩에서도 원격 VTEP 경로의 next-hop이 leaf 루프백으로 유지됨

---

## v0.8 — RoCEv2 (2026-10-09)

### 추가
- 실험 12 **RoCEv2** — WSL 커널에 빠진 rdma_rxe·crc32_generic 모듈 빌드(`tools/build-rxe.sh`), g1~g4를 VRF로 만들어 leafN:eth5에 붙임(`setup.sh`), R1 설치·연결 ~ R7 카운터(`run.sh`), RDMA 도구 상자 이미지(`tools/Dockerfile`)
- 모니터링 4차: 수집기가 rxe 카운터를 `clos_rdma_*`로 내보냄(도구 상자 컨테이너에 docker exec), 알람 `RoceRetransmitting`(재전송 비율 0.2% 초과)·`RoceQPFailed`

### 검증
- 12: 6.6 커널의 rxe는 netns를 모름(경로 찾기·수신 소켓이 init_net 고정). VRF 포트로 들어온 패킷은 수신 장치가 VRF로 바뀌어 rxe를 VRF 장치에 붙여야 받음
- 12: RoCE MTU 1024 → 4096에서 0.63 → 1.92 Gb/s. 손실 1%에서 RoCE −75%, TCP는 거의 그대로. 캡처에서 PSN 34 손실 → NAK(PSN Sequence Error) → 34부터 다시 보냄
- 12: 300Mbit 포트 3:1 인캐스트, 버퍼 16KB에서 합계 19~26Mbit(송신자가 시간의 72~91%를 65ms 타이머 대기). 타이머 4.2ms·1ms는 드랍만 4배, 버퍼 4MB는 ping 100배, 송신 창 4는 드랍 0·포트의 76~92%
- 12: QP마다 UDP 출발 포트가 다르지만 리프 해시 정책 0에서는 전부 한 스파인, 정책 1에서 QP 4개가 451:456MB
- 12: rxe 장치를 막 만든 직후 첫 측정에서 WSL 전체가 멈추는 문제(6번 중 3번) — 원인 미확인, 장 README에 기록

### 변경
- `ws-shot.ps1`: Wireshark가 최소화된 채(약 160×28) 열리면 창을 되살리고 크기가 맞을 때까지 다시 시도

## v0.7 — 패킷의 일생 (2026-10-05)

### 추가
- 실험 08 **패킷의 일생** — EVPN 주소록(Type-3, Type-2, 커널 fdb) → 여섯 지점 캡처로 캡슐화·스파인 통과·도착 → 순수 L3(h1 ↔ h3)와 비교하는 C-1~C-7

### 검증
- 08: Type-2의 넥스트홉 10.255.1.3이 leaf1 fdb에 `dst 10.255.1.3`으로 설치. 98바이트 프레임이 148바이트로, 스파인 통과 때 바깥 MAC과 TTL(64 → 63)만 바뀜
- 08: 이사 응답 공백 0.35초(IP 유지, MAC Mobility 순번 0 — 옛 자리가 먼저 철회됨). 같은 10.10.10.0/24를 VNI 10010·10020이 함께 씀
- 08: ARP 억제는 리프가 IP↔MAC을 알 때만 효과(4 → 3 → 0개). 이 랩의 Type-2는 리프 브리지에 IP가 없어 MAC만 실림
- 08: 기본 MTU(서버 9500, VXLAN 장치 1500)에서 EVPN 쪽 TCP 0 Mbit/s. EVPN 광고만 끄면 언더레이 세션 2/2인 채 v1 → v3 100% 손실

### 변경
- 예정 실험 번호: 세션 테이블 고갈 08 → 09, 비대칭 라우팅 09 → 11
- `ws-shot.ps1`: `powershell -File`로 부를 때 쉼표로 이어 붙은 `-Col` 값을 열 여러 개로 나눔

## v0.6 — 마이크로버스트 (2026-10-04)

### 추가
- 실험 10 **마이크로버스트** — 100Mbit·버퍼 64KB 포트(`tc tbf`)에 평균 90Mbit/s를 고르게 / 300개씩 몰아서. 캡처를 1ms 단위로 다시 세는 `io.py`, Wireshark 화면, Grafana 렌더

### 검증
- 10: 고르게 보내면 손실 0, 몰아서 보내면 61~83% 손실. 큐에서 58,368개를 버렸지만 `tx_dropped`는 0이라 모니터링은 드랍 0·알람 0. 5초 평균 송신 속도는 90 → 25Mbit/s로 낮아 보였다. 버스트 하나는 300개가 12µs 간격으로 들어와 124개만 114µs(=100Mbit/s) 간격으로 나감

### 변경
- 브랜치 `test/experiments` → `test`
- README 화면 설명의 실험 링크(05 → 01) 수정

## v0.5 — 패킷 캡처로 읽는 장애 (2026-10-02 ~ 10-03)

설계 확장보다 트러블슈팅과 패킷 흐름 관찰에 집중하기로 방향을 바꾼 버전.
장마다 장애 지점 앞뒤를 동시에 캡처하고, Wireshark 화면·원본 pcap·모니터링 성적표를 함께 둔다.

### 장애 시나리오
- **추가** 01 숨은 MTU 결함 + 스파인 장애 — 정상 → 결함 → 스파인 먹통 → 복구 시간표로 성공률·알람 시각 측정, 모니터링 성적표
- **추가** 02 물리 계층 불량, 03 L2 루프·브로드캐스트 스톰, 04 DNS 장애 — run.sh, 원본 pcap, Wireshark 화면, 패킷 흐름 해설
- **변경** 옛 실험 01(HTTP 전송 + MTU)을 `experiments/_archive/01-http-mtu`로 옮김

### 기본 검증 이관 (docs/EXPERIMENTS.md → 05~07)
- **추가** 05 ECMP 분산, 06 링크 다운 수렴, 07 스파인 무응답과 BFD — EXPERIMENTS §1·§2를 패킷 캡처로 다시 잰 장
- **결정** EXPERIMENTS §3(VXLAN/EVPN)·§4(unnumbered, listen range)는 장으로 옮기지 않는다

### 모니터링
- **추가** 2차 — 인터페이스 바이트·드랍·에러·MTU(`clos_if_*`), 서버 TCP 재전송(`clos_host_tcp_*`), 이웃별 세션 끊김 누적(`clos_bgp_peer_drops_total`). 노드별 병렬 수집. 알람 `InterfaceDropping`, `FabricMTUMismatch`, 대시보드 데이터플레인 줄
- **추가** 3차 — 리프→스파인 링크마다 작은 ping과 MTU 크기 ping(`clos_link_probe_success`), 알람 `LinkLargeFrameLoss`·`LinkProbeDown`, 대시보드 블랙박스 줄

### 도구
- **추가** `experiments/_tools/` — `lab.sh`(netns 실행·캡처 함수), `prep-hosts.sh`(서버 도구 설치), `ws-shot.ps1`(Wireshark 화면 저장, `-Col`·`-Crop`), `detail.sh`(tshark 상세), `timeline.sh`(T0 기준 ping 공백·BGP·BFD 타임라인), Wireshark 프로필
- **변경** `lab.sh`의 `WINROOT`를 환경변수로 덮어쓸 수 있게 함
- **변경** `ws-shot.ps1` 버그 수정 — 창 핸들 변수 `$h`가 높이 `$H`를 덮어써(PowerShell은 대소문자 구분 없음) `-H`가 무시되던 문제

### 문서·구조
- **추가** README 프로젝트 개요와 패킷 캡처·모니터링 화면, 바로 가기 카드
- **추가** DESIGN.md 그림 3장(3계층 vs spine-leaf, 장비별 AS, 번호에서 계산되는 값)과 한눈에 요약. 목표 규칙과 지금 랩의 차이를 적음
- **변경** 실험 번호 정리 — 옛 04·05·06 → 02·03·04, 옛 02 → 05, 예정이던 03 플래핑 → 06, 옛 12·13·14 → 07·08·09, 예정이던 07·08·09 → 12·13·14. 목록에서 15~17(EVPN, unnumbered, 동적 이웃) 제거
- **삭제** README의 실측 결과 표, BFD 전후 데모, 검증의 흐름 절 (장애 시나리오 표로 합침)
- **삭제** 관측 사각지대 실험(1·2차 모니터링 비교). 결과와 화면은 같은 MTU 장애를 다루는 01의 "모니터링이 자라 온 과정" 절로 옮김
- **변경** 실험 번호 07·08·09 → 05·06·07, 예정 목록은 08~13으로 당김
- **변경** 장마다 "진단할 때 볼 것"·"이 랩의 한계"를 없애고 짧은 결론 글로 바꿈
- **변경** 예정 목록을 세션 테이블 고갈, 비대칭 라우팅 + 상태 기반 방화벽, 마이크로버스트 셋으로 줄임

### 검증
- 01: 숨은 결함만 있을 때 HTTP 61%, spine1 먹통이 겹치면 0%, 작은 ping은 내내 정상. 리프는 hold timer 만료(8.8초) 뒤에 spine1을 뺌. 리눅스 TCP의 해시 재선택(`net.core.txrehash`)이 veth를 넘어 리프의 ECMP 선택을 바꿔, 기본값에서는 결함 링크를 스스로 피해 갔다(HTTP 100%). 링크 프로브는 MTU 결함을 잡았지만 포워딩만 멈춘 스파인은 커널이 ping에 대답해 못 잡았다
- 02: 비트 깨짐 4%에서 h3 TCP 체크섬 오류 5·IP 헤더 오류 4, 몰린 손실에서 ping 9개 연속 소실. 이 커널(WSL 6.6)에서 netem `loss 5%`는 동작하지 않고 `loss gemodel`은 동작
- 03: ARP 하나 → 3초에 136만 패킷, MAC 표 오염, EVPN MAC Mobility 순번 증가와 중복 감지. 루프 포트의 IPv6 멀티캐스트만으로도 스톰이 시작됨
- 04: DNS 고장 방식별 실패 시간 3.3초(잘못된 레코드) / 0.2초(프로세스 중지) / 10.8초(DROP)
- 01(모니터링 비교): 1차 모니터링 아래 MTU 장애는 Established 16/16, 알람 0. 2차는 같은 장애에 알람 2. scrape 평균 0.8초로 1차와 같음
- 05: 정책 0은 40:0. 정책 1은 갈리지만 5-tuple이 같은 흐름을 다시 보내면 40개 중 18개가 다른 링크로 — 서버 소켓의 해시값(skb->hash)을 그대로 씀. 정책 3(필드 0x37)은 0개
- 06: 끊김 0.20초. leaf1은 T0+0.011에 남은 링크로, leaf4는 T0+0.118에 경로 교체. spine1은 철회 대신 valley path(65001 65012 65002 65011)를 광고. 복구 시 OPEN 충돌(Connection Collision Resolution), 무손실. 스파인 AS 통일(RFC 7938 권고)은 미결정 항목으로 남김
- 07: BFD 없이 7.61초(마지막 KEEPALIVE에서 9.003초 뒤 Hold Timer Expired), BFD 300ms×3에서 1.15초(마지막 BFD에서 0.900초 뒤 Down). 얼린 스파인의 커널은 TCP ACK를 계속 보냄

## v0.4 — 장애 시나리오 구조 (2026-09-30)

### 추가
- `experiments/` — 장애 시나리오를 실험별 디렉터리로 쌓는 구조. 목록·규칙은 `experiments/README.md`, 새 실험 뼈대는 `experiments/_template/`
- `experiments/01-http-mtu/` — HTTP 대용량 전송 + MTU 불일치 실험 (2026-09-26 실측분, 지금은 `_archive/`)

### 변경
- `experiments/http-mtu` → `experiments/01-http-mtu`. `lib.sh`의 윈도우 사본 경로를 디렉터리 이름에서 계산하도록 바꿈
- README에 장애 시나리오 절 추가, Roadmap의 MTU 항목을 실험 01로 닫음

## v0.3 — 관측 (2026-09-20)

### 추가
- `monitoring/` — Prometheus + Grafana 관측 시나리오. 자작 경량 수집기(`exporter/collector.py`)가 docker 소켓으로 `vtysh … json`을 긁어 지표로 (frr_exporter 바이너리 대신 — 배포 단순·투명)
  - 기대 세션 수를 이름 규칙에서 **계산**해 `clos_bgp_peers_expected`로 내보내고 알람은 `established < expected` ([DESIGN](docs/DESIGN.md) 원칙 유지, 리프 늘려도 규칙 불변)
  - 알람 3종(세션부족·노드먹통·경로급감), Grafana 대시보드 7패널, `up.sh`/`down.sh`/`detect-time.sh`
- `assets/vxlan-packet.svg` — VXLAN 캡슐화 패킷 구조도, `assets/monitoring-flow.svg` — 관측 데이터 흐름도

### 검증
- **감지 시간 실측** — spine2 조용한 먹통 → 모니터링이 아는 시점까지: BFD 없음 **14.1초**, BFD 300ms×3 **6.2초** ([EXPERIMENTS §5](docs/EXPERIMENTS.md))
  - 관측 지연은 `scrape_interval`(5초)이 하한 — 데이터플레인 복구(1.2초)와 다른 축
  - 장애 시 대시보드: Established 8/16, 기대 미달 4, 알람 5

## v0.2 — 확장 검증과 운영 문서 (2026-08-25 ~ 09-10)

날짜 표시가 없는 항목은 09-10.

### 검증
- (08-25) 스파인 이웃 목록을 지우고 대역만 열어도(listen range) 리프 4대가 20초 안에 스스로 재접속하는 것 확인
- (09-10) spine1↔leaf1 한 링크만 BGP unnumbered로 바꿔 **혼합 상태**에서 확인 — 세션이 fe80(link-local)으로 붙고, IPv4 경로의 넥스트홉이 `fe80::… via eth1`로 바뀜. 나머지 `/31` 링크와 섞인 ECMP, 서버 간 통신 모두 정상. RA 설정 불필요 (FRR 10.2.1)

### 결정
- **BGP unnumbered 채택.** 전체 전환은 확장 작업 3번(§7 정리 재배포) 때 한 번에 한다
- **스파인 동적 이웃(listen range) 기각.** 링크에 IP가 없어지면서 쓸 곳이 사라졌다

### 추가
- (08-25) `docs/10-확장규칙.md` — 이름·AS·주소·포트 규칙, 리프 추가 절차, 규칙과 어긋나는 곳 목록
- (08-25) `scripts/listen-range-test.sh`, 30일 실습 코스 (`docs/40-하루5분-30일.md`, `scripts/day.sh` 등)
- (09-10) `scripts/unnumbered-test.sh` — 위 검증 재현 (실행 중 설정만 바꾸고 자동 원복)
- `CHANGELOG.md` — 이 파일
- `docs/RUNBOOK.md` — 따라 하는 절차: 랩 띄우기, 원본→사본 동기화, 재배포, 리프 1대 추가, 고장 훈련 한 판
- `docs/LOG.md` — 고장 훈련 기록 (날짜·증상·원인·해결 한 줄씩)

### 변경
- `docs/10-확장규칙.md` → **`docs/RULES.md`로 이름 변경**
  - §5-2(unnumbered 검증·판단 기준·잃는 것·함정) 추가, §7에 링크 주소 항목 추가, 미결정 2건 닫음
  - §6 리프 추가 절차는 RUNBOOK R4로 옮기고, listen range 기각에 맞춰 고칠 곳 개수 표를 바로잡음
  - §3 리프 상한 `128대 → 99대` — 원래도 AS 대역(99대)이 먼저 걸렸다. 링크 주소 상한은 unnumbered로 없어진다
- `scripts/day.sh`·`days.sh` — 훈련 기록 파일 `docs/41-하루5분-기록.md → docs/LOG.md`, 칸 `일차·날짜·제목·예측·메모 → 날짜·증상·원인·해결`. 윈도우 원본을 찾으면 그쪽에 써서 깃에 남는다
- `docs/00-프로젝트-흐름.md` — 확장 작업 로드맵(1~6)과 의존 관계 추가, 파일 목록 갱신, 삭제된 문서 참조 제거
- `README.md` — 문서 안내 표, 스크립트 표에 `listen-range-test.sh`·`unnumbered-test.sh` 추가, 30일 코스 안내 제거

### 삭제
- `docs/40-하루5분-30일.md` — 30일 코스 안내 문서 (훈련 자체는 `scripts/day.sh`로 계속된다. 절차는 RUNBOOK R5)
- `docs/90-현업-예상질문.md`

## v0.1 — 랩 초기 구성 (2026-08-10)

### 추가
- 랩 초기 구성 — 스파인 2 + 리프 4 + 서버 6, eBGP 언더레이·ECMP·장애 측정·BFD·VXLAN/EVPN 스크립트와 문서

### 변경
- 줄바꿈을 LF로 고정 (`.gitattributes`) — 윈도우에서 체크아웃해도 WSL 셸 스크립트가 깨지지 않게
