# 실험 19 — VXLAN의 ECMP 엔트로피: 바깥 헤더는 VTEP 쌍 하나

> [실험 목록](../../README.md) · 앞 장 [05 ECMP 분산](../../_completed/05-ecmp-hash/README.md), [16 RoCE over VXLAN](../16-roce-vxlan-ecn/README.md) · 실행 기록 [capture/run-output.txt](capture/run-output.txt)

오버레이 흐름이 아무리 많아도 VXLAN 바깥 IP 는 leaf1(10.255.1.1) → leaf3(10.255.1.3) **한 쌍**이다. 스파인을 고르는 건 leaf1 의 ECMP 해시이고, 베이스 패브릭은 `fib_multipath_hash_policy=0`(L3: 출발·목적 IP)이다.
vxlan 은 안쪽 흐름의 해시로 **바깥 UDP 출발 포트**를 바꿔 엔트로피를 싣는다. 05장은 순수 L3 흐름으로 정책을 비교했고, 이 장은 그 질문을 VXLAN 바깥 헤더로 옮긴다 — 해시가 그 출발 포트를 보는가, 큰 흐름 둘이 같은 스파인에 부딪히면 얼마나 잃는가.

## 장애 구성

```
            ┌─ eth1 (200Mbit) ── spine1 ─┐
  g1 ── leaf1                             leaf3 ── g3        VNI 10010, 바깥 10.255.1.1 → 10.255.1.3
            └─ eth2 (200Mbit) ── spine2 ─┘
          (캡처 ① eth1, ② eth2: 안쪽 흐름 출발 포트 ↔ 링크)
```

| Phase | leaf1 설정 | 보내는 것 | 보는 것 |
|---|---|---|---|
| P0 | 정책 0 (L3) | TCP 8흐름 10초 | 링크별 흐름 수, 합계 |
| P1 | 정책 1 (L4) | 같은 8흐름 | 〃 |
| P3 | 정책 3, fields 0x37 (5-튜플) | 같은 8흐름 | 〃 |
| E | 정책 1 | 큰 흐름 2개(출발 포트만 새로) × 20회 | 충돌 비율과 그때 합계 |
| Q | 정책 1 | RoCE QP 1·2·4·8 | rxe 의 QP 별 UDP 출발 포트가 갈리는가 |
| S | 정책 1 + vxlan `srcport 49152 49153` | TCP 8흐름 | 바깥 출발 포트를 하나로 묶으면 |

## 실행

```bash
experiments/_wip/16-roce-vxlan-ecn/run2/scripts/setup.sh     # g1~g4 + rxe (spine2:eth3 은 이 장이 잠깐 올렸다 되돌린다)
experiments/_wip/19-vxlan-ecmp-entropy/run.sh                # P0 P1 P3 E Q S (약 6분), 끝에 restore.sh
```

## 예측 (실행 전에 적음)

- P0: 바깥 IP 쌍이 하나라 8흐름 전부 한 링크로 간다(05장의 40:0 과 같은 이유). 합계는 200Mbit 상한.
- P1: 바깥 UDP 출발 포트가 흐름마다 달라 갈린다. 합계 300Mbit 대.
- P3: P1 과 비슷하게 갈린다.
- E: 둘이 같은 링크에 갈 확률은 약 절반. 충돌이면 합 ~190, 갈리면 ~380.
- Q: rxe 는 QP 마다 출발 포트를 달리 쓰므로 QP 가 늘면 갈린다. QP 1 개는 한 링크.
- S: 출발 포트가 하나면 정책 1 이어도 P0 처럼 한 링크로 몰린다. 단, 실행 중인 vxlan 장치의 `srcport` 를 바꿀 수 있을지는 모르겠다(못 바꾸면 기록만).
