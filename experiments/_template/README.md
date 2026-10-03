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

> **한 줄 요약 — 이 장애가 무엇이고 어떻게 보이는지.**

| | |
|---|---|
| **넣은 장애** | |
| **겉으로 보인 것** | |
| **핵심 숫자** | |
| **왜 그랬나** | |
| **결정적 증거** | 캡처에서 원인을 확정한 패킷 |
| **찾는 법** | 다음에 같은 증상을 만나면 어디부터 볼지 |
