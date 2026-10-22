# 실험 13 2회차 — RoCE over VXLAN: ECN 전달 누락 (데스크톱, 60초 × 3회)

> [13장 본문(1회차·요약)](../README.md) · [실험 목록](../../../README.md) · 진행: 2026-10-14 ~ 10-15 · 커널 6.6.114.1-microsoft-standard-WSL2

1회차(노트북, 30초 × 2회, v1·x2·x4 컨테이너, 병목 100Mbit)와 같은 질문을 **다른 구성**으로 다시 쟀다: 서버는 rxe 가 붙는 WSL 기본 netns 의 VRF(g1~g4), 병목 300Mbit, 60초 × 3회, 그리고 rxe 트랙 두 개(그대로 / 흉내 DCQCN).
이 문서는 2회차의 상세 노트다. 처음에 18번으로 시작했다가 노트북 기록과 합치면서 여기로 옮겼다.

스파인이 VXLAN **바깥** 헤더에 찍은 혼잡 표시(CE)가 리프 VTEP에서 **안쪽** 헤더로 옮겨지지 않으면, 혼잡 제어 고리(스위치 표시 → 수신측 알림 → 송신측 감속)가 어떻게 끊기는지 잰다.

```
   g1(leaf1)  g2(leaf2)  g4(leaf4)            모두 VNI 10010, 10.10.10.0/24
        \        |        /                   gN = WSL 기본 netns 의 VRF vrN + veth xgN ↔ leafN:eth6(br10010)
         leaf1/2/4 업링크 eth1 ──── 장애2: 바깥 ECT 지우기(egress)
                 │  (spine2:eth3 은 내려서 경로를 spine1 로 고정)
               spine1 ── eth3 egress: 병목 300Mbit + RED(ecn)   ← 바깥 헤더에 CE
                 │
         leaf3 eth1 ingress ─────── 장애1: 바깥 CE → ECT(0) (디캡 직전)
         leaf3 (VTEP 디캡)
         leaf3 eth6 egress ──────── 대조군 병목 자리(디캡 이후, 안쪽 헤더에 CE)
                 │
                g3 (수신)
```

## 예측 (실험 전에 먼저 작성)

본 측정(Step 2~5) 결과를 보기 전에 적었다. 단, 스크립트 점검용 10초 시험 실행(트랙별 1회)은 먼저 돌렸고, 거기서 장애1 의 TCP 처리량이 277 → 184 Mbit 로 줄어드는 것을 이미 봤다 — 아래 Q2 예측은 핸드오프 가설을 그대로 옮긴 것이고 시험 실행을 보고 고치지 않았다. Step 1 의 답(Q1)은 측정 전에 `drivers/net/vxlan/vxlan_core.c` 를 먼저 읽어서 예측했다.

- **Q1 전달:** 리눅스 vxlan 은 캡슐화 때 `ip_tunnel_ecn_encap()` 로 안쪽 ECN 을 바깥에 복사하고(안쪽 CE 는 바깥 ECT(0)으로), 디캡 때 `INET_ECN_decapsulate()` 로 바깥 CE 를 안쪽에 옮긴다(RFC 6040). `tos` 옵션은 DSCP 만 바꾸고 ECN 처리에는 영향이 없을 것이다. → 그렇다면 장애1은 리눅스 VTEP 에서는 저절로 생기지 않는, **인위적 재현**이다.
- **rxe:** 실험 11에서 "rxe 는 ECN 을 찍지도 반응하지도 않는다"고 봤다. CE 를 받아도 CNP 를 만들지 않을 것이다 → 트랙 B(TCP+DCTCP)가 메인이 된다.
- **Q2 장애1 (핸드오프의 핵심 가설 그대로):** 스파인 표시 카운터는 정상인데 수신측 알림(ECE/CNP)이 0이 된다. 송신측이 감속하지 않아 큐가 버퍼 끝까지 차고 드랍 → 재전송 폭증 → **처리량 붕괴**.
- **Q2 장애2:** 스파인이 표시 대신 드랍한다. 손실 기반으로 떨어져 재전송이 늘고 처리량이 준다.
- **대조군:** 병목이 디캡 뒤에 있으면 표시가 안쪽 헤더에 바로 찍히므로 장애1 은 아무 영향이 없다.

## Step 0 점검 결과 (rxe DCQCN 지원 여부, 선택한 트랙)

전체 출력: [data/step0.txt](data/step0.txt) · 스크립트 [scripts/step0.sh](scripts/step0.sh)

| 항목 | 결과 |
|---|---|
| 토폴로지 | 스파인 2 + 리프 4 (eBGP 언더레이, VXLAN/EVPN). 베이스 VNI 10010 은 leaf1·leaf3 에만 있어서 실험 중에만 leaf2·leaf4 에도 만들었다 |
| rxe 위치 | rxe 는 netns 를 몰라서(실험 11) 서버를 컨테이너가 아니라 **WSL 기본 netns 의 VRF** 로 만들고, veth 반대쪽을 각 리프의 `br10010` 포트(eth6)로 꽂았다 → 리프 뒤 VNI 안 호스트 |
| 커널 / 모듈 | 6.6.114.1, `rdma_rxe`·`crc32_generic` 은 `/root/kbuild` 에서 빌드한 모듈 (실험 11 0단계), `tcp_dctcp` 있음 |
| MTU | 서버·VNI·브리지 9000, 언더레이 9500, RoCE active_mtu 4096. 8900B DF ping 통과. (베이스의 VNI MTU 1500 은 RoCE 4KB 프레임을 못 넘겨서 실험 중 9000 으로 올렸다) |
| rxe 계수기 | `ack_deferred completer_retry_err duplicate_request … sent_pkts` 16개. mlx5 의 `np_cnp_sent`·`rp_cnp_handled`·`np_ecn_marked_roce_packets` 같은 혼잡 제어 계수기가 **없다** |
| rxe 소스 | `cnp/ecn/congest` 를 쓰는 .c 파일 0개, `IB_OPCODE_CNP` 쓰는 곳 0개. BTH 의 FECN/BECN 은 `rxe_hdr.h` 에 함수만 있고 호출 0개 |
| **실측** | spine1:eth3 RED(ecn) 병목 + g1→g3 RoCE 10초(tclass 106 = DSCP 26 + ECT(0)). g3 앞(xg3)에 CE 패킷 **67,035개**가 도착. g3 → g1 은 **4,203개 전부 ACK(opcode 0x11), CNP(0x81) 0개**. g1 이 받은 CNP 0 |

**판단:** rxe 는 CE 를 받아도 CNP 를 만들지 않고, CNP 를 받는 코드도 없다. DCQCN 이 없으므로 "CE 를 못 받으면 감속을 못 한다"는 장애를 rxe 로는 만들 수 없다 → **트랙 B(TCP + DCTCP)를 메인으로 전환**했다.
트랙 A(rxe 그대로)는 "VXLAN 안쪽 RoCE 의 ECN 비트"와 "병목 손실 때 NAK/go-back-N" 관찰용으로 같이 돌렸고, 실험 11 의 흉내 DCQCN(`tools/dcqcn.py`, g3 앞에서 안쪽 CE 를 보고 UDP CNP 를 보내 송신측 htb 속도를 깎는다)을 얹은 **트랙 A'** 를 덧붙였다. A' 는 진짜 NIC 의 DCQCN 이 아니라 흉내라는 점을 결과 읽을 때 늘 같이 적는다.

## Step 1 — 신호 전달 (Q1)

전체 출력: [data/step1.txt](data/step1.txt) · CSV: [step1-encap.csv](data/step1-encap.csv), [step1-decap.csv](data/step1-decap.csv), [step1-traffic.csv](data/step1-traffic.csv)

**캡슐화 (안쪽 → 바깥).** g1 이 안쪽 TOS 를 바꿔 ping, 송신 리프 업링크 leaf1:eth1 에서 바깥 TOS 를 봤다 (조합마다 5개, 전부 같은 값).

| 안쪽으로 보낸 TOS | vxlan `tos 0`(기본) 바깥 | `tos inherit` 바깥 | `tos 0x68` 바깥 |
|---|---|---|---|
| 0x00 Not-ECT | 0x00 Not-ECT | 0x00 Not-ECT | 0x68 Not-ECT |
| 0x01 ECT(1) | 0x01 ECT(1) | 0x01 ECT(1) | 0x69 ECT(1) |
| 0x02 ECT(0) | 0x02 ECT(0) | 0x02 ECT(0) | 0x6a ECT(0) |
| 0x03 CE | **0x02 ECT(0)** | **0x02 ECT(0)** | **0x6a ECT(0)** |
| 0x6a DSCP26+ECT(0) | 0x02 ECT(0) | 0x6a | 0x6a |
| 0x6b DSCP26+CE | 0x02 ECT(0) | 0x6a | 0x6a |

ECN 두 비트는 옵션과 상관없이 늘 복사된다. 안쪽 CE 는 바깥에 CE 가 아니라 ECT(0)으로 나간다(RFC 6040 normal mode: 이미 찍힌 표시를 바깥 경로의 혼잡으로 다시 세지 않게). `tos` 옵션이 바꾸는 것은 **DSCP 뿐**이다. 기본값(0)에서는 RoCE 의 DSCP 26 이 바깥에서 사라진다 — 언더레이가 DSCP 로 RoCE 클래스를 나눈다면 그건 따로 문제가 된다(이 실험 범위 밖, 후속 과제).

**디캡 (바깥 → 안쪽).** spine1:eth3 egress 에서 pedit 으로 바깥 ECN 을 강제로 바꾸고, g3 앞(xg3)에서 안쪽 TOS 와 도착 수를 봤다. `tos 0` 과 `tos inherit` 결과가 같았다.

| 바깥 \ 안쪽 | Not-ECT | ECT(1) | ECT(0) | CE |
|---|---|---|---|---|
| Not-ECT | Not-ECT | ECT(1) | ECT(0) | CE |
| ECT(1) | Not-ECT | ECT(1) | **ECT(1)** | CE |
| ECT(0) | Not-ECT | ECT(1) | ECT(0) | CE |
| **CE** | **드랍 (0/5)** | **CE** | **CE** | CE |

바깥 CE 는 안쪽이 ECT 면 안쪽 CE 로 옮겨지고, 안쪽이 Not-ECT 면 표시를 전할 방법이 없어 **패킷을 버린다**(커널 로그 `vxlan: non-ECT from 10.255.1.1 with TOS=0x3`, 37줄). RFC 6040 의 디캡 표 그대로다.

**실제 병목에서.** spine1:eth3 에 RED(ecn) 를 걸고 TCP(DCTCP)·RoCE 를 5초씩 흘려, 스파인 표시 / leaf3 업링크 바깥 CE / g3 앞 안쪽 CE 를 셌다.

| vxlan tos | 트래픽 | 스파인 표시 | leaf3:eth1 바깥 CE | xg3 안쪽 CE | 송신 리프 업링크 바깥 ECT(0) |
|---|---|---|---|---|---|
| 0 | TCP | 42,491 | 42,491 | **42,491** | 2000/2000 (표본) |
| 0 | RoCE | 46,578 | 46,578 | **46,578** | 1999/1999 |
| inherit | TCP | 42,639 | 42,639 | 42,639 | 2000/2000 |
| inherit | RoCE | 46,801 | 46,801 | 46,801 | 2000/2000 |
| 0x68 | TCP | 42,337 | 42,337 | 42,337 | 2000/2000 |
| 0x68 | RoCE | 46,466 | 46,466 | 46,466 | 2000/2000 |

세 숫자가 한 개도 어긋나지 않는다. **리눅스 vxlan 은 기본값에서 CE 를 안쪽으로 옮긴다.** 따라서 아래 장애1 은 "바깥 CE 를 안쪽에 반영하지 않는 VTEP"(RFC 6040 이전 터널 규격들은 디캡 때 바깥 ECN 을 무시하는 동작을 허용했다)을 tc pedit 으로 **흉내 낸 인위적 재현**이다.
(Step 0·1 의 RoCE 병목 버퍼는 4MB, Step 2~5 는 1MB. 표시 전달만 보는 단계라 결과에 영향이 없다.)

## Step 2~5 — 정상 · 장애1 · 장애2 · 대조군 (Q2)

스크립트: [run-all.sh](scripts/run-all.sh) → 시나리오마다 [bottleneck.sh](scripts/bottleneck.sh)·[inject-decap.sh](scripts/inject-decap.sh)·[inject-encap.sh](scripts/inject-encap.sh)·[control.sh](scripts/control.sh)로 상태를 만들고 [measure.sh](scripts/measure.sh)가 60초 잰다(1초 계수기 [sampler.py](scripts/sampler.py)). 회차 순서는 정상 → 장애1 → 장애2 → 대조군을 한 바퀴로 세 바퀴.
집계 [analyze.py](scripts/analyze.py) → [data/summary.csv](data/summary.csv)(회차별), [data/summary-mean.csv](data/summary-mean.csv)(평균·표준편차), `data/timeseries-<트랙>.csv`(1초).

- 경로 고정: spine2:eth3 을 내려 leaf3 로 가는 VXLAN 을 전부 spine1:eth3 하나로 (병목이 한 곳).
- 병목: spine1:eth3 egress htb 300Mbit + RED(ecn). TCP 는 DCTCP 식 계단(평균 큐 30KB 넘으면 전부 표시, 한도 1MB), RoCE 는 실험 11 문턱(100~300KB, 한도 1MB).
- 대조군: 같은 큐를 leaf3:eth6(디캡 뒤, g3 앞) egress 로 옮기고 장애1 필터는 그대로 켠다.

### 트랙 B — TCP + DCTCP (메인), 60초 × 3회 평균

| | 정상 | 장애1 디캡 CE 누락 | 장애2 캡슐화 ECT 누락 | 대조군 + 장애1 |
|---|---|---|---|---|
| 합계 처리량 (수신, Mbit/s) | 276.5 | **144.1 (−48%)** | 276.7 | 286.3 |
| 병목 표시 | 511,256 | **765,293** | 0 | (leaf3:eth6) 186,043 |
| 병목 드랍 | 19 | 768 | **41,595** | 3 |
| leaf3 업링크 바깥 CE | 511,256 | 764,607 | 0 | 0 |
| g3 앞 안쪽 CE | 511,256 | **0** | 0 | 582,480 ※ |
| 수신측 알림 ECE | 358,941 | **6** | 6 | 170,562 |
| 재전송 | 20 | 1,107 | **41,608** | 6 |
| 병목 큐 평균 | 30KB | **416KB** | 24KB | 32KB |
| 송신 srtt 평균 / cwnd 평균 | 0.9ms / 11KB | **22.3ms / 133KB** | 1.0ms / 11KB | 1.0ms / 12KB |
| 전면 정지(합계 < 10Mbit) | 0 | **3·3·4번, 31·19·21초** | 0 | 0 |

※ 대조군의 안쪽 CE 는 GRO 로 묶인 skb 하나에 찍힌 표시가 세그먼트 수만큼 세어진 값이다(flower 계수기는 gso_segs 로 센다). 1회차에서 추정한 것과 같은 현상.
ECE 6 은 연결 셋의 SYN/SYN-ACK 이다(ECN 협상 플래그).

![처리량 — 회차별](figures/1-throughput.png)

**장애1 은 한 번 무너지는 게 아니라 주기적으로 멈춘다.** 1회차 30초 창에서는 정지가 한 번(약 15초)이었는데, 60초 창에서는 세 회차 모두 "약 8초 전속 → 3~14초 완전 정지"가 3~4번 반복됐다(위 그림 주황 선). 패턴은 1회차와 같다: ECE 가 0 이라 DCTCP 의 cwnd 가 계속 커지고(평균 133KB, 정상의 12배), 큐가 1MB 한도에 닿으면 꼬리 드랍 수백 개가 세 흐름을 같은 순간에 RTO 로 보낸다. 세 송신의 1초 처리량이 같은 초에 0 이 되고 같은 초에 돌아온다(`data/timeseries-tcp.csv` 의 tx_g1/g2/g4).
**정지 구간에도 병목 드랍이 초당 1~4개 남는다(큐는 0).** 1회차의 "설명 못 한 것"과 같은 현상이 여기서도 3회 모두 나왔다(정지 구간 드랍 합 24·29·27개).

### 추적 — 정지의 정체는 TCP 가 아니라 BGP 였다

[scripts/diag-stall.sh](scripts/diag-stall.sh) 로 장애1 40초를 다시 돌리며 RED 내부 계수기(0.2초), 병목 앞뒤 Not-ECT 캡처, g1 TCP 캡처, ECT ping 을 같이 봤다. 요약 [data/diag-summary.txt](data/diag-summary.txt), 원자료 `data/diag-stall/`, `data/diag-stall-protect/`.

1. **정지 중 드랍은 큐 한도(pdrop)가 아니라 RED 의 `early` 다.** 한 주기(약 8초 전속)에 꼬리 드랍은 시작 때 수백 개, 끝에서 1~5개뿐이고, 정지 구간에는 큐 0 인데 `early` 만 초당 1~3개 오른다. 표시(marked)는 0 — TCP 는 그 사이 아무것도 보내지 않는다.
2. **g1 은 정지 중 같은 seq 를 0.2 → 0.44 → 0.9 → 1.8 → 3.7초 간격으로 재전송한다.** RTO 지수 백오프다. 재전송이 계속 사라진다는 뜻인데, 재전송 패킷은 ECT(tos 0x2) 라 RED 가 버릴 대상이 아니다(표시만 한다).
3. 같은 구간에 **g2·g4 의 재전송이 g1 인터페이스(xg1)에도 보였다.** 송신 리프들이 g3 의 MAC 을 잃고 BUM 으로 흘렸다는 뜻 → EVPN 경로가 철회됐다.
4. 그래서 BGP 를 봤다. **spine1–leaf3 세션만 15번 끊겼다 붙었다**(다른 리프 세션은 0번, 이유는 leaf3 의 hold timer 9초 만료 통지). 장애1 40초에 3번 — 전속 구간 약 8초가 hold timer 9초와 같은 길이다.
5. 대조 진단 `PROTECT=1`: 같은 병목·같은 장애에서 BGP(TCP 179)와 ARP 만 RED 밖의 우선 클래스로 보냈다.

| 장애1, 40초 | 보호 없음 | BGP·ARP 보호 |
|---|---|---|
| spine1–leaf3 BGP 끊김 | **3번** | 0번 |
| 처리량 < 10Mbit 인 초 | 10 | **0** |
| 평균 처리량 | 181 Mbit | **278 Mbit** (정상 276.5 와 같음) |
| 큐 한도 드랍(pdrop) | 391 | 983 |
| RED early 드랍 | 63 | 1 |
| ECT ping 손실 (50ms) | 196/798, 공백 2.1·5.7·2.1초 | **0/827** |

**정리하면:** ECE 를 못 받은 송신이 감속하지 않아 큐가 1MB 근처에 붙어 있고, RED 평균 큐가 최대 문턱 위에 머문다. 이 상태의 ECN RED 는 ECT 패킷은 표시하지만 **Not-ECT 패킷은 전부 버린다.** 스파인이 직접 내보내는 BGP keepalive(와 ARP)가 바로 그 Not-ECT 다. 세 번 연달아 사라지면 leaf3 가 세션을 끊고, 언더레이에서 leaf3 루프백·EVPN 경로가 빠져 leaf3 로 가는 모든 것이 멈춘다. 세션이 다시 붙으면 재개 — 그리고 또 9초 뒤. 큐가 빈 정지 구간에도 `early` 드랍이 남는 건 RED 평균 큐가 그동안 거의 줄지 않기 때문으로 보인다(htb 아래 RED 는 큐가 비는 순간을 알아채지 못해 평균이 패킷이 올 때만 조금씩 준다 — 커널 코드로 확인하지는 않았다).
보호하면 꼬리 드랍은 더 많아져도(983) TCP 는 SACK 으로 다 회복해 처리량이 정상과 같다. **장애1 의 처리량 붕괴는 TCP 혼잡 붕괴가 아니라 컨트롤 플레인 붕괴였다.** 핸드오프의 가설(큐 넘침 → 재전송 폭증 → 붕괴)과 1회차의 해석(세 흐름 동시 RTO)은 증상은 맞게 봤지만 원인 고리가 틀렸다.

실제 스위치에서는 장비가 직접 만드는 제어 트래픽을 보통 따로 보호된 큐(CoPP·network-control 클래스)로 내보내므로 이 고리가 그대로 생기지는 않는다. 다만 "ECN 큐에 Not-ECT 트래픽이 같이 서 있으면, 송신이 ECN 에 반응하지 않는 순간 그 트래픽이 먼저 굶는다"는 건 그대로다 — 예를 들어 같은 클래스에 섞인 UDP 모니터링, ECN 을 안 켠 다른 테넌트 흐름.

장애2 는 TCP 에는 거의 상처가 없다. 표시 대신 드랍이 41,595개 났지만 SACK 으로 빠진 조각만 다시 보내 처리량은 정상과 같다(276.7). srtt 도 1.0ms — 드랍이 큐를 30KB 근처에서 잘라 주므로 오히려 지연은 정상과 같다.

### 트랙 A′ — rxe + 흉내 DCQCN, 60초 × 3회 평균

| | 정상 | 장애1 | 장애2 | 대조군 + 장애1 |
|---|---|---|---|---|
| 합계 처리량 (perftest, Mbit/s) | 213.4 | **123.8 (−42%)** | **23.0 (−89%)** | 213.6 |
| 수신측 알림 CNP | 26,118 | **0** | 0 | 25,924 |
| 병목 표시 / 드랍 | 167,403 / 9,156 | 496,978 / **120,720** | 0 / **234,139** | (leaf) 169,522 / 8,732 |
| g3 NAK (go-back-N) | 384 | 1,630 | 1,802 | 372 |
| 병목 큐 평균 | 134KB | **510KB** | 69KB | 120KB |
| 전면 정지 | 0 | 4·4·5번, 1~3초씩 | 0 | 0 |

![재전송·알림·드랍](figures/3-retrans-signal.png)

흉내 DCQCN 에서도 장애1 은 같은 꼴이다: CNP 가 0 이 되자 송신 셋이 1000Mbit 상한 그대로 보내고, 큐가 1MB 를 넘쳐 드랍 12만 개, go-back-N NAK 4배, 짧은 정지 4~5번.
**TCP 와 정반대인 곳은 장애2 다.** RoCE 는 장애2 에서 −89% 로 장애1 보다 훨씬 심하게 무너졌다. 바깥이 Not-ECT 라 RED 가 평균 큐 100KB 부터 확률적으로 버리기 시작하고(드랍 23만 개), RC 전송의 go-back-N 은 패킷 하나를 잃을 때마다 그 뒤 전부를 다시 보낸다. TCP 는 같은 드랍을 SACK 으로 거의 공짜로 흡수했다. **같은 비트 하나가 지워져도, 전송 계층이 손실에 얼마나 약한가에 따라 어느 장애가 더 아픈지가 뒤집힌다.**

### 트랙 A — rxe 그대로

> **측정 함정 (2026-10-15):** WSL 을 다시 띄워 패브릭을 재배포한 뒤 `setup.sh` 를 돌렸는데, `state/spine2-eth3-down` 파일이 남아 있어서 "이미 내렸다"고 보고 spine2:eth3 을 내리지 않았다. 경로 고정이 풀린 채 g1·g4 흐름이 병목 없는 spine2 로 3Gbit/s 씩 흘렀고(첫 진단에서 발견), 그 사이 잰 rxe 트랙 회차는 버렸다. 이제 setup.sh 는 파일이 아니라 링크의 실제 상태(`operstate`)를 본다.

60초 × 3회 (경로 고정을 바로잡은 뒤 다시 잼, [data/run-all-roce.txt](data/run-all-roce.txt)).

| rxe 그대로, 3회 평균 | 정상 | 장애1 | 장애2 | 대조군 + 장애1 |
|---|---|---|---|---|
| g3 앞 수신 (재전송 포함, Mbit/s) | 217.4 | 205.5 | **115.8** | 277.1 |
| perftest 합계 (Mbit/s) ※ | 172.7 | 153.8 | **28.0 (−84%)** | 143.5 |
| 병목 표시 / 드랍 | 455,379 / 70,892 | 434,556 / 63,188 | 0 / **313,622** | (leaf) 663,048 / 169,182 |
| 안쪽 CE / CNP | 384,658 / 0 | **0** / 0 | 0 / 0 | 493,992 / 0 |
| g3 NAK / 송신 재시도 | 989 / 2,372 | 947 / 2,131 | **2,575 / 3,773** | 2,092 / 3,337 |

※ perftest 는 회차마다 송신 셋 중 하나가 결과를 0 이나 빈 값으로 남기는 일이 잦았다(rxe 가 60초 동안 QP 를 잃었다 되찾는 것으로 보인다). 그래서 정상과 장애1 비교는 수신측 계수기(g3 앞 바이트)로 읽는다.

rxe 는 CE 에 반응하지 않으므로 **정상과 장애1 이 같다**(217 vs 206, NAK 989 vs 947) — 안쪽 CE 가 38만 개에서 0 이 돼도 아무도 그 차이를 모른다. 혼잡 제어가 없으니 정상에서도 1MB 버퍼가 넘쳐 드랍 7만 개, NAK 약 1,000 이 난다. 장애2 는 바깥이 Not-ECT 라 RED 가 평균 큐 100KB 부터 버리기 시작하고(드랍 31만 개), go-back-N 으로 perftest 합계가 −84% 까지 떨어진다 — 흉내 DCQCN 트랙(−89%)과 같은 꼴이다. 1회차에서 못 본 "병목 손실 때의 NAK/go-back-N" 은 이 장애2 회차가 보여 준다.
대조군에서 수신이 오히려 많은(277) 것은 병목이 디캡 뒤 veth 에 있어 GRO 로 묶인 큰 skb 단위로 큐에 들어가기 때문으로 보인다(TCP 대조군과 같은 현상). perftest 는 143 으로 정상보다 낮아 재전송 몫이 크다.

## 1회차와 비교

| | 1회차 (노트북) | 2회차 (데스크톱) |
|---|---|---|
| 구성 | v1·x2·x4 컨테이너, 병목 100Mbit, RED 30~45KB / 600KB | rxe 붙는 VRF g1·g2·g4, 병목 300Mbit, RED 30~31KB / 1MB |
| 회차 | 30초 × 2 | 60초 × 3 |
| 장애1 처리량 | −50% | −48% |
| 장애1 정지 | 한 번, 약 15초 | 3~4번, 3~14초씩 반복 |
| 정지 중 빈 큐 드랍 | 초당 1~3개 (원인 미확정) | 초당 1~4개 → **BGP keepalive 가 RED 에 버려져 hold timer 만료**로 밝힘 |
| 장애2 (TCP) | 처리량 그대로, 재전송 9,852 | 처리량 그대로, 재전송 41,608 |
| RoCE 쪽 | rxe 점검만 (tclass 0 회차 실패) | rxe 그대로: 장애1 차이 없음, 장애2 −84%(NAK 2.6배). 흉내 DCQCN: 장애1 −42%, **장애2 −89%** |
| Q1 | 리눅스 vxlan 은 기본값에서 전달 | 같음 + 4×4 디캡 표(바깥 CE + 안쪽 Not-ECT → 드랍) |

구성이 달라도 장애1 의 모양(ECE 0 → cwnd 폭주 → 한도 드랍 → 동시 RTO → 전면 정지)은 같았다. 길게 재 보니 그 정지가 **되풀이**된다는 게 새로 보였다.

## 원상복구

각 시나리오 끝에서 병목·장애 필터는 run-all.sh 가 걷었다. 18·19·20장까지 이 셋업 위에서 돌린 뒤, 마지막에 각 장의 restore.sh 와 [scripts/teardown.sh](scripts/teardown.sh) 로 전부 되돌리고 상태를 다시 쟀다 → [data/teardown.txt](data/teardown.txt) (2026-10-16 00:30).

- BGP: 스파인 2대 IPv4·EVPN 각 4/4, 리프 4대 각 2/2 Established (spine2:eth3 다시 올림)
- leaf1 → leaf3 VTEP 경로 넥스트홉 2개(ECMP 복구), leaf1 의 VNI 10010 원격 VTEP 은 원래대로 leaf3 하나 (leaf2·leaf4 의 실험용 VNI 제거)
- v1 → v3(EVPN), h1 → h2·h3·h4 손실 0%, `check.sh` 전부 OK
- 남은 qdisc 없음, WSL 기본 netns 의 `tcp_ecn=2`·`tcp_congestion_control=cubic`·`tcp_l3mdev_accept=0` 원래 값, VRF·rxe_x 장치·lo 의 192.0.2.18 제거

## 후속 과제

- ~~`diag-stall.sh` — 정지 구간 빈 큐 드랍의 정체~~ → BGP keepalive 가 ECN RED 에 굶어 hold timer 만료 (위 추적)
- 흉내 DCQCN 트랙의 짧은 정지(1~3초)도 같은 원인인지 — 같은 진단을 RoCE 로
- htb 아래 RED 의 평균 큐가 빈 큐에서 줄지 않는 것을 커널 코드(`red_dequeue` 의 idle 시작 조건)로 확인
- 장애1 을 흐름 하나에만 걸어 공정성 보기 (1회차 후속 과제와 같음)
