# 변경 기록

패치노트처럼 **무엇이 바뀌었는지**를 날짜별로 쌓는다. 최신이 위.
설계 근거는 [docs/DESIGN.md](docs/DESIGN.md), 측정 결과는 [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md)에 적는다.

## 쓰는 법

- 분류는 다섯 개: **추가** · **변경** · **삭제** · **검증**(랩에서 실측) · **결정**(미결정 항목을 닫음)
- 작업 하나가 끝날 때마다 맨 위 날짜 아래에 한 줄씩 적는다. 커밋 메시지와 같은 말이어도 된다
- 재배포가 필요한 변경에는 **⚠ 재배포**를 붙인다 — 받아 쓰는 쪽이 `./scripts/deploy.sh redeploy`를 해야 하는지 바로 알 수 있게
- AS·주소·포트 같은 **값이 바뀌면 `이전 → 이후`**를 적는다

---

## 2026-10-02 (2)

### 추가
- `experiments/_tools/` — 챕터 공통 도구: `lab.sh`(netns 실행·캡처 함수), `prep-hosts.sh`(서버 도구 설치), `ws-shot.ps1`(Wireshark 화면 저장), `detail.sh`(tshark 상세), Wireshark 프로필
- 실험 04 물리 계층 불량, 05 L2 루프·브로드캐스트 스톰, 06 DNS 장애 — 장마다 run.sh, 원본 pcap, Wireshark 화면, 패킷 흐름 해설

### 검증
- 04: 비트 깨짐 4%에서 h3 TCP 체크섬 오류 5·IP 헤더 오류 4, 몰린 손실에서 ping 9개 연속 소실. 이 커널(WSL 6.6)에서 netem `loss 5%`는 동작하지 않고 `loss gemodel`은 동작
- 05: ARP 하나 → 3초에 136만 패킷, MAC 표 오염, EVPN MAC Mobility 순번 증가와 중복 감지. 루프 포트의 IPv6 멀티캐스트만으로도 스톰이 시작됨
- 06: DNS 고장 방식별 실패 시간 3.3초(잘못된 레코드) / 0.2초(프로세스 중지) / 10.8초(DROP)

## 2026-10-02

### 추가
- 수집기 2차 — 인터페이스 바이트·드랍·에러·MTU(`clos_if_*`), 서버 TCP 재전송(`clos_host_tcp_*`), 이웃별 세션 끊김 누적(`clos_bgp_peer_drops_total`). 노드별 병렬 수집
- 알람 `InterfaceDropping`, `FabricMTUMismatch`. 대시보드에 데이터플레인 줄(패널 8개)
- `experiments/02-observability-gap/` — 같은 MTU 장애를 1차·2차 모니터링 아래에서 주입하는 `probe.sh`

### 검증
- 1차 모니터링 아래 MTU 장애: 전송 정지, Established 16/16, **알람 0**
- 2차 아래 같은 장애: **알람 2** (MTU 불일치 spine1:eth3, spine1-leaf3 링크 드랍). scrape 평균 0.8초로 1차와 같음

## 2026-09-30

### 추가
- `experiments/` — 장애 시나리오를 실험별 디렉터리로 쌓는 구조. 목록·규칙은 `experiments/README.md`, 새 실험 뼈대는 `experiments/_template/`
- `experiments/01-http-mtu/` — HTTP 대용량 전송 + MTU 불일치 실험 (2026-09-26 실측분). 스크립트 7개와 결과 기록

### 변경
- `experiments/http-mtu` → `experiments/01-http-mtu`. `lib.sh`의 윈도우 사본 경로를 디렉터리 이름에서 계산하도록 바꿈
- README에 장애 시나리오 절 추가, Roadmap의 MTU 항목을 실험 01로 닫음

## 2026-09-20

### 추가
- `monitoring/` — Prometheus + Grafana 관측 시나리오. 자작 경량 수집기(`exporter/collector.py`)가 docker 소켓으로 `vtysh … json`을 긁어 지표로 (frr_exporter 바이너리 대신 — 배포 단순·투명)
  - 기대 세션 수를 이름 규칙에서 **계산**해 `clos_bgp_peers_expected`로 내보내고 알람은 `established < expected` ([DESIGN](docs/DESIGN.md) 원칙 유지, 리프 늘려도 규칙 불변)
  - 알람 3종(세션부족·노드먹통·경로급감), Grafana 대시보드 7패널, `up.sh`/`down.sh`/`detect-time.sh`
- `assets/vxlan-packet.svg` — VXLAN 캡슐화 패킷 구조도, `assets/monitoring-flow.svg` — 관측 데이터 흐름도

### 검증
- **감지 시간 실측** — spine2 조용한 먹통 → 모니터링이 아는 시점까지: BFD 없음 **14.1초**, BFD 300ms×3 **6.2초** ([EXPERIMENTS §5](docs/EXPERIMENTS.md))
  - 관측 지연은 `scrape_interval`(5초)이 하한 — 데이터플레인 복구(1.2초)와 다른 축
  - 장애 시 대시보드: Established 8/16, 기대 미달 4, 알람 5

## 2026-09-10

### 검증
- spine1↔leaf1 한 링크만 BGP unnumbered로 바꿔 **혼합 상태**에서 확인 — 세션이 fe80(link-local)으로 붙고, IPv4 경로의 넥스트홉이 `fe80::… via eth1`로 바뀜. 나머지 `/31` 링크와 섞인 ECMP, 서버 간 통신 모두 정상. RA 설정 불필요 (FRR 10.2.1)

### 결정
- **BGP unnumbered 채택.** 전체 전환은 확장 작업 3번(§7 정리 재배포) 때 한 번에 한다
- **스파인 동적 이웃(listen range) 기각.** 링크에 IP가 없어지면서 쓸 곳이 사라졌다

### 추가
- `scripts/unnumbered-test.sh` — 위 검증 재현 (실행 중 설정만 바꾸고 자동 원복)
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

## 2026-08-25

### 검증
- 스파인 이웃 목록을 지우고 대역만 열어도(listen range) 리프 4대가 20초 안에 스스로 재접속하는 것 확인

### 추가
- `docs/10-확장규칙.md` — 이름·AS·주소·포트 규칙, 리프 추가 절차, 규칙과 어긋나는 곳 목록
- `scripts/listen-range-test.sh`
- 30일 실습 코스 (`docs/40-하루5분-30일.md`, `scripts/day.sh` 등)

## 2026-08-10

### 추가
- 랩 초기 구성 — 스파인 2 + 리프 4 + 서버 6, eBGP 언더레이·ECMP·장애 측정·BFD·VXLAN/EVPN 스크립트와 문서

### 변경
- 줄바꿈을 LF로 고정 (`.gitattributes`) — 윈도우에서 체크아웃해도 WSL 셸 스크립트가 깨지지 않게
