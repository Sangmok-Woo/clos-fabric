# experiments — 장애 시나리오

베이스 패브릭(스파인 2 + 리프 4, eBGP 언더레이 + VXLAN/EVPN)은 고정해 두고, 그 위에서 장애를 하나씩 재현한다.
실험 하나가 디렉터리 하나다. 장마다 장애 지점 앞뒤를 캡처하고, Wireshark 화면·모니터링 화면·원본 pcap을 함께 둔다.

패브릭을 세우면서 한 기본 검증(ECMP·수렴·BFD·EVPN 등)은 지금 [docs/EXPERIMENTS.md](../docs/EXPERIMENTS.md)에 있다.
이 중 ECMP·링크 다운·스파인 무응답(EXPERIMENTS §1·§2)은 패킷을 직접 캡처해 다시 측정하고 07~09번으로 옮겼다.
옮기기가 끝나면 docs/EXPERIMENTS.md는 지우고, 메인 README의 실측 결과 표도 장애 시나리오 표로 합친다.

## 목록

| # | 실험 | 주입하는 장애 | 상태 |
|---|---|---|---|
| 01 | [숨은 MTU 결함 + 스파인 장애](01-hidden-mtu-meets-spine-failure/README.md) | spine2 포트 MTU 1500인 채로 spine1이 조용히 죽음 | 완료 |
| 02 | [물리 계층 불량](02-physical-corruption/README.md) | tc netem으로 비트 깨짐 4%, 몰려오는 손실 | 완료 |
| 03 | [L2 루프·브로드캐스트 스톰](03-broadcast-storm/README.md) | VXLAN 브리지에 veth 양 끝을 꽂아 고리 | 완료 |
| 04 | [DNS 장애](04-dns-failure/README.md) | 잘못된 레코드 / DNS 프로세스 중지 / 53번 DROP | 완료 |
| 05 | [관측 사각지대](05-observability-gap/README.md) | MTU 장애를 1차·2차 모니터링 아래에서 각각 주입 | 완료 |
| 06 | 간헐적 플래핑 | 링크를 주기적으로 끊었다 붙임 | 예정 |
| 07 | [ECMP 분산](07-ecmp-hash/README.md) | 해시 정책 0/1/3에서 흐름 40개의 링크별 분산, 같은 흐름을 다시 보내기 | 완료 |
| 08 | [링크 다운 수렴](08-link-down-convergence/README.md) | 지금 쓰는 스파인 링크를 내림, 인터페이스 다운 감지 | 완료 |
| 09 | [스파인 무응답과 BFD](09-spine-freeze-bfd/README.md) | 스파인 freeze, BGP 타이머 vs BFD 300ms×3 | 완료 |
| 10 | 세션 테이블 고갈 | NAT 포트 범위를 좁히고 연결 폭주 | 예정 |
| 11 | IP 충돌·잘못된 서브넷 | 일부 대상만 통신 불가 | 예정 |
| 12 | 비대칭 라우팅 + 상태 기반 방화벽 | 리턴 경로만 다르게 → 응답 드랍 | 예정 |
| 13 | 설정 변경 직후 장애 | route-map 한 줄 실수 → 특정 서비스 차단, 롤백 | 예정 |
| 14 | 마이크로버스트 | 순간 트래픽 몰기, 모니터링 주기에 묻히는지 | 예정 |

번호는 읽는 순서다. 패킷 캡처로 읽는 장(01~04)을 앞에, 모니터링 장(05)을 뒤에 둔다 (2026-10-02에 옛 02·04·05·06을 05·02·03·04로, 예정이던 03 플래핑을 06으로 옮겼다).

_archive/에는 이전 실험(옛 01번 HTTP 전송 + MTU 장애)을 보관한다.

## 공통 도구 (`_tools/`)

| 파일 | 하는 일 |
|---|---|
| `lab.sh` | 챕터 스크립트가 source 하는 함수 모음. 노드 netns 에서 호스트 도구 실행(`nsx`), 캡처 시작·종료(`cap_start`/`cap_stop`) |
| `timeline.sh` | 수렴 장(13·14)의 시간 계산: 장애 시각 T0 기준 ping 공백(`reply_gap`), 응답 없는 요청 수(`lost`), BGP·BFD 메시지 타임라인(`bgp_events`) |
| `prep-hosts.sh` | 서버 6대에 curl·httpd·iperf3·dnsmasq 설치 (랩을 새로 띄울 때 한 번) |
| `ws-shot.ps1` | (윈도우) pcap 을 Wireshark 로 열어 창을 PNG 로 저장. `-Col "제목=필드"`로 열 추가, `-Crop N`으로 패킷 목록만 |
| `detail.sh` | (윈도우) 패킷 하나의 상세 트리를 텍스트로 (tshark -V) |
| `wireshark-profile/` | 스크린샷용 Wireshark 프로필: 기본 열, 체크섬 검사 켬 |

## 규칙

1. **베이스를 바꾸지 않는다.** `clos.clab.yml`과 `configs/`는 그대로 둔다. 실험에 필요한 값은 `setup.sh`가 실행 중에 바꾼다.
2. **바꾼 값은 되돌린다.** 원래 값을 `state/`에 적어두고 `teardown.sh`가 원복한 뒤 검증까지 한다. 실험이 끝나면 베이스는 시작 전과 같아야 한다.
3. **디렉터리 하나로 닫는다.** 스크립트·문서·캡처가 전부 그 안에 있다. 다른 실험의 장애를 다시 쓸 때만 그 실험의 스크립트를 부르고, README에 적는다. 경로는 `lib.sh`가 자기 위치에서 계산한다.
4. **큰 파일은 올리지 않는다.** `pcap/`, `state/`, `files/`는 실험 디렉터리의 `.gitignore`에 넣는다.

## 디렉터리 구성

```
experiments/NN-이름/
├── README.md      무엇을 보려는가, 장애 주입 방법, 단계별 명령
├── RESULTS.md     실측 기록 (표와 숫자)
├── CASE.md        사례 정리 — 증상 → 추적 → 원인 → 복구 (선택)
├── lib.sh         공통 변수. 다른 스크립트가 source 한다
├── setup.sh       실험 환경 준비
├── fault.sh       inject / restore / status
├── teardown.sh    원복과 검증
└── .gitignore     pcap/ state/ files/
```

관찰용 스크립트(`cap.sh`, `via.sh` 같은 것)는 실험마다 필요한 만큼 더한다.

## 새 실험 추가

```bash
cp -r experiments/_template experiments/02-이름
```

1. `README.md`의 빈칸을 채우고 `lib.sh`에 관찰 구간과 값을 적는다
2. `setup.sh` / `fault.sh` / `teardown.sh`를 쓴다
3. 위 목록 표와 [메인 README](../README.md#장애-시나리오)의 표에 한 줄씩 더한다
4. [CHANGELOG](../CHANGELOG.md)에 적는다
