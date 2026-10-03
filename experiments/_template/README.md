# 실험 NN — 제목

> [실험 목록](../README.md) · 결과는 [RESULTS.md](RESULTS.md)

무엇을 보려는 실험인지 두세 줄로.

## 장애

| 항목 | 값 |
|---|---|
| 주입 지점 | 예: spine1:eth3 |
| 바꾸는 값 | 예: MTU 9216 → 1500 |
| 관찰 구간 | 예: v1(leaf1) → v3(leaf3) |
| 기대하는 증상 | |

## 파일

| 파일 | 하는 일 |
|---|---|
| `setup.sh` | |
| `fault.sh` | `inject` / `restore` / `status` |
| `teardown.sh` | 전부 원복하고 검증 |

## 시작

```bash
cd /root/labs/clos-fabric
./scripts/deploy.sh up      # 랩이 없을 때만
cd experiments/NN-이름
./setup.sh
```

## Phase 0 — 베이스라인

장애를 넣기 전 값을 먼저 잰다.

## Phase 1 — 장애 주입

```bash
./fault.sh inject
```

## Phase 2 — 복구

```bash
./fault.sh restore
./teardown.sh
```

## 결론

무엇을 넣었고 겉으로 어떻게 보였는지, 숫자 한두 개와 왜 그랬는지를 두세 문단의 글로 쓴다.
마지막에 다음에 같은 증상을 만나면 어디부터 볼지 한두 문장.
