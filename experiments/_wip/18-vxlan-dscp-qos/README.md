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
