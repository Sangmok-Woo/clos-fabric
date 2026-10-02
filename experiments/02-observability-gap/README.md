# 실험 02 — 관측 사각지대: 세션은 멀쩡한데 데이터가 막힐 때

> [실험 목록](../README.md) · 결과는 [RESULTS.md](RESULTS.md)

1차 모니터링([monitoring/](../../monitoring/README.md))은 BGP 세션과 경로만 본다.
실험 01의 MTU 장애는 세션을 건드리지 않는다. 작은 BGP 패킷은 MTU 1500을 문제없이 지나가기 때문이다.
그래서 같은 장애를 1차 모니터링 아래에서 다시 넣어 무엇을 놓치는지 확인하고,
데이터플레인 지표를 더한 2차 모니터링이 그것을 잡는지 본다.

## 장애

| 항목 | 값 |
|---|---|
| 주입 지점 | spine1:eth3 (leaf3 방향) |
| 바꾸는 값 | MTU 9216 → 1500 |
| 관찰 구간 | v1(leaf1) → v3(leaf3), 68MB HTTP 전송 |
| 기대하는 증상 | spine1을 타는 플로우만 멈춘다. 세션은 그대로다 |

환경 준비와 장애 주입은 실험 01의 `setup.sh` / `fault.sh`를 그대로 쓴다 (같은 장애를 다시 넣는 실험이라서).

## 2차 모니터링에서 더한 것

수집기(`monitoring/exporter/collector.py`)에 데이터플레인 지표를 더했다. 새 컨테이너는 없다.

| 지표 | 출처 | 잡는 것 |
|---|---|---|
| `clos_if_{rx,tx}_dropped_total` 외 바이트·에러 | 라우터의 `/proc/net/dev` | 링크에서 버려지는 패킷 |
| `clos_if_mtu` | `/sys/class/net/ethN/mtu` | 설정 불일치 |
| `clos_host_tcp_retranssegs_total` | 서버의 `/proc/net/snmp` | 서버가 체감하는 손실 |
| `clos_bgp_peer_drops_total` | FRR `connectionsDropped` | scrape 사이의 짧은 세션 끊김 (실험 03용) |

인터페이스에는 `link` 라벨을 붙인다. 포트 번호가 계산식이라(spineS:ethL ↔ leafL:ethS) 토폴로지 파일 없이 정해진다.

알람 두 개를 더했다 (`monitoring/prometheus/alerts.yml`).

| 알람 | 조건 |
|---|---|
| `InterfaceDropping` | 30초 사이 드랍이 늘어난 링크. veth는 드랍 하나를 양쪽 끝(보낸 쪽 TX, 받은 쪽 RX)에 모두 적으므로 링크 단위로 묶는다 |
| `FabricMTUMismatch` | 패브릭 포트 MTU가 전체 중앙값과 다르다. 기대값을 상수로 박지 않는다 |

## 파일

| 파일 | 하는 일 |
|---|---|
| `lib.sh` | Prometheus 질의 `q`, 전송 한 번 `fetch`, 대시보드 렌더 `render` |
| `probe.sh` | 장애 주입 → 전송 N회 → 그 순간 모니터링이 본 것을 Prometheus에 묻는다 → 복구 |
| `img/` | 대시보드 렌더 (1차 장애 중 / 2차 정상 / 2차 장애 중) |

## 시작

```bash
cd /root/labs/clos-fabric/monitoring && ./up.sh       # 관측 포함 토폴로지
cd .. && sleep 20 && ./scripts/evpn-apply.sh
cd experiments/01-http-mtu && SIZE_MB=256 ./setup.sh   # MTU 통일, httpd, 테스트 파일
cd ../02-observability-gap
```

## Phase 1 — 1차 모니터링 아래에서 장애

2차 수집기를 올리기 전 상태에서 한다. 이미 2차로 올렸다면 `git stash`로 `monitoring/`을 되돌리고 `./up.sh`.

```bash
RENDER=v1-during-fault ./probe.sh 6
```

## Phase 2 — 2차 모니터링 아래에서 같은 장애

```bash
. ./lib.sh && render v2-healthy     # 정상 상태 먼저
RENDER=v2-during-fault ./probe.sh 8
```

Grafana `http://localhost:3000`의 아래쪽 데이터플레인 줄에서 시간축으로 볼 수 있다.

## 종료

```bash
../01-http-mtu/teardown.sh
cd ../../monitoring && ./down.sh
```
