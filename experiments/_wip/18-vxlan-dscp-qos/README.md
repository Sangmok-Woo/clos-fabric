# 실험 18 — VXLAN 바깥 DSCP 소실: 언더레이 QoS가 RoCE를 못 알아본다

> [실험 목록](../../README.md) · 앞 장 [16 RoCE over VXLAN: ECN 전달 누락](../16-roce-vxlan-ecn/README.md) · 실행 기록 [capture/run-output.txt](capture/run-output.txt)

16장 2회차 Step 1에서 리눅스 vxlan 은 ECN 두 비트는 늘 바깥으로 복사하지만, **DSCP 는 `tos` 옵션에 따라** 다르게 다룬다는 것을 봤다. 기본값(`tos 0`)이면 RoCE 의 DSCP 26 이 바깥 헤더에서 0 이 된다.
스파인은 바깥 헤더만 보고 큐를 고른다. 그러면 언더레이에 RoCE 전용 클래스를 만들어 둬도 RoCE 는 그 줄에 서지 못하고 TCP 대량 전송과 섞인다. 이 장은 그 차이를 처리량·재전송(NAK)·지연으로 잰다.

## 장애 구성

```
  g1(leaf1) RoCE  tclass 106 = DSCP 26 + ECT(0)  ─┐
  g2(leaf2) TCP cubic ×4  DSCP 0                  ─┼─ VXLAN ─ spine1 ─[eth3 egress 300Mbit]─ leaf3 ─ g3
  g4(leaf4) TCP cubic ×4  DSCP 0                  ─┘           클래스 1:10 바깥 DSCP 26 → 보장 200Mbit, 우선순위 0
                                                                클래스 1:20 나머지       → 보장 100Mbit, 우선순위 1
                                                                (각 버퍼 256KB, 남는 대역은 서로 빌려 씀)
```

| 항목 | 값 |
|---|---|
| 바꾸는 값 | 네 리프 vxlan `tos`: `0`(기본) / `inherit` / `0x68`(고정) |
| 병목 | spine1:eth3 egress htb 300Mbit, 바깥 dsfield 0x68/0xfc 로 분류 (spine2:eth3 은 16장 setup 이 내려 경로 고정) |
| RoCE 송신 | g1 의 xg1 에서 DSCP 26 클래스를 150Mbit 로 묶음 (burst 15k). 아래 "추적" 참고 |
| 관찰 | RoCE 처리량(ib_write_bw 64KB, 30초 × 3회), g3 NAK·g1 재시도, 클래스별 바이트·드랍, 64B RDMA Write 지연(ib_write_lat 2만 번, TCP 짐을 얹고), spine1:eth3 바깥 TOS 표본 |

| 시나리오 | 내용 |
|---|---|
| S0 | RoCE 혼자 (짐 없음, tos 0) — 기준 |
| S1 | tos 0 + TCP 8흐름 — 바깥 DSCP 0, RoCE 가 BE 클래스로 |
| S2 | tos inherit + TCP 8흐름 — 안쪽 DSCP 를 바깥으로, RoCE 만 클래스 10 |
| S3 | tos 0x68 + TCP 8흐름 — 모든 VXLAN 이 DSCP 26, TCP 도 클래스 10 으로 |

## 실행

```bash
experiments/_wip/16-roce-vxlan-ecn/run2/scripts/setup.sh    # g1~g4 VNI 10010 + rxe, 경로 spine1 고정
experiments/_wip/18-vxlan-dscp-qos/run.sh                   # S0~S3 (약 12분), 끝에 tos 0·스파인 큐 원복
experiments/_wip/18-vxlan-dscp-qos/restore.sh               # 중간에 멈췄을 때
```

## 예측 (실행 전에 적음)

- S0: rxe 혼자면 300Mbit 포트를 거의 채운다(16장 2회차에서 rxe 셋이 합 ~250Mbit).
- S1: RoCE 가 cubic 8흐름과 256KB 한 줄에 선다. cubic 이 큐를 채우고 꼬리 드랍이 나면 RoCE 는 go-back-N 으로 무너진다 — 처리량 30Mbit 이하, NAK 수백~수천, 지연 99% 는 큐 대기(256KB ≈ 7ms) 근처까지.
- S2: RoCE 만 우선순위 클래스로 가서 200Mbit 이상, NAK 거의 0, 지연은 S0 근처. TCP 는 나머지(≈100Mbit 이상)를 쓴다.
- S3: 클래스를 나눈 의미가 없어져 S1 과 비슷하게 무너진다. 클래스 20 은 비고 클래스 10 에서 드랍.

## 숫자

30초 × 3회 (세 회차가 거의 같아 평균만 적는다, 회차별은 `capture/S*/bw.csv`). 지연은 64B RDMA Write 2만 번(ib_write_lat), 같은 TCP 짐을 얹고.

| | 바깥 DSCP (RoCE) | RoCE (Mbit/s) | TCP 8흐름 (Mbit/s) | g3 NAK | 클래스 10 드랍 | 클래스 20 드랍 | 지연 typical / 99% / 99.9% (µs) |
|---|---|---|---|---|---|---|---|
| S0 RoCE 혼자 | 0 | 150 | — | 0 | 0 | 0 | 13.3 / 42 / 134 |
| S1 `tos 0` (기본) | **0** | **12** | 215 | 581 | 0 | 16,846 | 13.3 / **3,433** / 3,525 |
| S2 `tos inherit` | **26** | **150** | 167 | **0** | 0 | 5,114 | 14.0 / **45** / 69 |
| S3 `tos 0x68` | 26 (TCP 도 26) | **12** | 214 | 590 | 16,951 | 0 | 13.5 / 3,494 / 3,527 |

바깥 TOS 는 S0 표본에서 RoCE 가 `outer 0x02 / inner 0x6a` — 기본값에서 DSCP 26 이 바깥에서 0 이 되는 것을 다시 확인했다. S1~S3 표본(spine1:eth3 앞 400개)은 먼저 시작한 TCP 로 채워졌다(S3 에서 TCP 의 바깥이 0x68/0x6a). RoCE 가 어느 클래스로 갔는지는 클래스 바이트로 보인다: S2 에서 클래스 10 이 정확히 573MB(= 150Mbit × 30초 + 헤더), S1 에서는 0.

## 추적 과정

1. **첫 시도: RoCE 혼자인데 64Mbit, 드랍 14만** ([first-try-output.txt](first-try-output.txt)). rxe 는 혼잡 제어가 없어 1Gbit 로 쏟아붓고, 300Mbit 포트의 256KB 버퍼를 넘쳐 go-back-N 으로 무너진다. 이 상태로는 어느 클래스에 서든 자기 과부하로 무너져 분류의 효과를 볼 수 없다.
2. 그래서 실험 12 R5 의 처방대로 송신측에서 RoCE 를 150Mbit 로 묶었다(실제 NIC 라면 DCQCN 이 자기 몫 안으로 맞춰 놓았을 속도). 처음에는 공통 스크립트의 병목 속도 변수 `RATE`(300Mbit)와 이름이 겹쳐 300 으로 걸렸고(S0 140Mbit, NAK 1,080), `ROCE_RATE` 로 바꾼 뒤 S0 가 150Mbit, NAK 0 으로 깨끗해졌다.

## 결론

RoCE 의 DSCP 26 은 vxlan `tos` 기본값(0)에서 바깥 헤더로 나가지 않는다. 스파인은 바깥만 보고 큐를 고르므로, 언더레이에 RoCE 전용 클래스(보장 200Mbit, 우선순위 0)를 만들어 둬도 RoCE 는 그 줄에 서지 못하고 TCP cubic 8흐름과 같은 BE 줄 256KB 에 섰다. 결과는 150 → **12Mbit(−92%)**, NAK 약 580, 지연 99% 가 42µs → **3.4ms**(80배). 스파인 설정도, RoCE 설정도 틀린 곳이 없는데 캡슐화 한 겹에서 표시 하나가 빠진 결과다.
`tos inherit` 하나로 RoCE 는 클래스 10 으로 가서 S0 와 똑같은 150Mbit, NAK 0, 지연 99% 45µs 를 지켰고 TCP 는 남은 대역(167Mbit)을 썼다. 반대로 `tos 0x68` 처럼 바깥 DSCP 를 고정값으로 박으면 모든 VXLAN — TCP 까지 — 이 RoCE 클래스로 몰려 S1 과 똑같이 무너졌다(이번엔 클래스 10 에서 드랍). 분류가 없는 것과 모두를 같은 등급으로 올리는 것은 결과가 같다.
16장과 이어 읽으면, vxlan 은 ECN 두 비트는 늘 안쪽을 따르게 해 주지만 DSCP 여섯 비트는 설정 하나에 달려 있다. RoCE 가 오버레이 위에서 이유 없이 느리고 NAK 가 보이면, 스파인의 클래스별 카운터에서 RoCE 클래스가 비어 있는지와 VTEP 의 `tos`(하드웨어 VTEP 이라면 DSCP 복사/매핑 설정)부터 본다.

## 한계

- RoCE 송신 속도를 tc 로 150Mbit 에 묶었다. 실제 RoCE NIC 는 DCQCN 이 속도를 정하고, PFC 가 RoCE 클래스를 무손실로 만든다 — PFC 가 있으면 S1 의 결과는 드랍이 아니라 BE 클래스 전체의 PAUSE(실험 12 R8 의 head-of-line blocking)로 나타날 수 있다
- 스파인 큐는 소프트웨어 htb 두 클래스. 실제 스위치의 strict priority / DWRR 와 버퍼 공유 방식이 다르다
- 바깥 TOS 표본이 TCP 위주로 잡혔다(RoCE 는 S0 표본과 클래스 바이트로 확인)
- 각 회차 30초, WSL CPU 8개 위의 Soft-RoCE

## 파일

| 파일 | 내용 |
|---|---|
| `run.sh` | S0~S3: tos 바꾸기 → 스파인 클래스 큐 → RoCE(+TCP) 30초 × 3 → 지연 → 원복 |
| `restore.sh` | 중간에 멈췄을 때 (tos 0, 스파인·xg1 큐 제거) |
| `sync.sh` | 윈도우 원본 ↔ WSL 실행 사본 |
| `capture/S*/` | bw.csv(회차별), ib_write_bw/lat 출력, spine1:eth3 바깥 TOS 표본 pcap |
| `first-try-output.txt` | 송신 속도 제한 없이 돌린 첫 시도 |
