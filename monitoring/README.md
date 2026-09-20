# monitoring — Prometheus + Grafana 관측 시나리오

> **한 줄** — 대시보드를 "만드는" 게 목적이 아니라, **장애를 모니터링이 알아채는 데 몇 초 걸리는지를 실측**하고,
> 그 값이 왜 데이터플레인 복구(BFD, 1.2초)와 다른지를 숫자로 보이는 시나리오다.

이 디렉터리는 베이스 패브릭 위에 관측 스택 3대를 얹은 **독립 하위 프로젝트**다. 베이스 설정(`../configs`)을
그대로 재사용하고, 토폴로지 이름도 `clos`라 컨테이너가 `clab-clos-*`가 되어 기존 스크립트(`failover.sh` 등)가 그대로 동작한다.

## 구성

```
  라우터 6대 (clab-clos-spine/leaf)
        │  vtysh -c 'show ... json'   (docker exec, 호스트 소켓 경유)
        ▼
  exporter  ── /metrics(:9600) ──►  prometheus  ──►  grafana
  (자작 수집기)   5초마다 scrape       알람 규칙        대시보드 :3000
```

- **exporter** — 제3자 바이너리(frr_exporter) 대신 **직접 쓴 경량 수집기**(`exporter/collector.py`).
  호스트 docker 소켓으로 라우터에 `docker exec … vtysh … json`을 돌려 지표를 만든다.
  사이드카·소켓 공유가 필요 없어 배포가 단순하고, 랩 철학("내가 이해하는 스크립트")과 맞는다.
- **prometheus** — 5초마다 수집기를 긁고 알람 규칙을 평가한다. `scrape_interval`이 곧 **감지 지연의 하한**이다.
- **grafana** — 익명 Admin으로 열리는 대시보드(로그인 불필요). datasource·대시보드 모두 provisioning으로 자동 주입.

## 핵심 설계 결정

1. **기대값을 상수로 박지 않는다** (DESIGN 원칙 그대로).
   수집기가 이름 규칙(`clab-clos-spineN/leafN`)으로 라우터를 스스로 찾고, 기대 세션 수를 계산한다
   (스파인=리프 수, 리프=스파인 수) → `clos_bgp_peers_expected`. 리프를 늘려도 알람 규칙·대시보드는 그대로다.
2. **핵심 알람은 "붙어야 할 세션이 안 붙었다"**.
   `clos_bgp_peers_established < clos_bgp_peers_expected`. RULES에서 걱정했던
   "붙어야 할 리프가 안 붙은 걸 사람이 못 알아챈다"의 답이 이 한 줄이다.
3. **관측 지연은 scrape 주기 아래로 못 내려간다**. BFD는 *BGP가 죽는 시점*을 앞당길 뿐,
   Prometheus는 *다음 scrape* 전까지 모른다. 그래서 모니터링 감지 시간 ≈ (BGP down까지) + (최대 1 scrape).

## 실행

```bash
cd monitoring
./up.sh            # 수집기 이미지 빌드 → 기존 clos 랩 정리 → 관측 포함 토폴로지 배포
./detect-time.sh   # 감지 시간 측정 (BFD off/on)
./down.sh          # 철거
```

- Grafana `http://localhost:3000` (익명 Admin) · Prometheus `http://localhost:9090` (Status ▸ Rules)
- 수집기 원본: `docker exec clab-clos-exporter wget -qO- 127.0.0.1:9600/metrics`

## 측정 결과 (2026-09-20)

spine2를 조용히 얼리고(`docker pause`), leaf1의 Established 세션이 줄어든 것을 **Prometheus가 아는 시점**까지 잰다.

| 구분 | 감지까지 | 왜 |
|---|---|---|
| BFD 없음 | **14.1초** | BGP hold timer(9초) 만료 후 세션 down → 다음 scrape(최대 5초) |
| BFD 300ms×3 | **6.2초** | 세션은 ~1초에 down → 그래도 다음 scrape 전까지는 못 봄 (하한 = 5초) |
| (대조) 데이터플레인 복구 | **1.2초** | BFD가 우회시킨 실제 통신 복구 — [../docs/EXPERIMENTS.md](../docs/EXPERIMENTS.md) |

**교훈**: BFD는 데이터플레인을 1.2초에 살리지만, *모니터링이 그 사실을 아는 데*는 scrape 주기에 묶여 6초가 걸린다.
둘은 다른 시간 축이다. 감지를 앞당기려면 scrape_interval을 줄여야 하고, 그건 부하와의 거래다.

대시보드 상태(실측 캡처):

| | Established | 기대 미달 노드 | 발생 알람 |
|---|---|---|---|
| 정상 | 16 / 16 | 0 | 0 |
| spine2 먹통 | 8 / 16 | 4 | 5 (RouterUnreachable×1 + BGPSessionsBelowExpected×4) |

## 알람 (`prometheus/alerts.yml`)

| 알람 | 조건 | 뜻 |
|---|---|---|
| `BGPSessionsBelowExpected` | established < expected | 붙어야 할 세션이 빠졌다 (핵심) |
| `RouterUnreachable` | `clos_up == 0` | vtysh 응답 없음 (노드 먹통) |
| `FabricRoutesDropped` | leaf RIB < 4 (10초) | 경로 광고가 끊겼다 |

## 이 환경에서 걸렸던 것 (재현 시 또 만난다)

- **Docker Hub DNS 타임아웃** — WSL 게이트웨이 resolver가 `registry-1.docker.io`를 자꾸 놓친다(깃허브는 됨).
  `/etc/resolv.conf`를 `8.8.8.8`/`1.1.1.1`로 바꾸면 pull 된다. 이미지 3개(docker/prometheus/grafana)만 받으면 이후는 오프라인.
- **`localhost` → IPv6(::1)** — clab 컨테이너는 IPv6가 있어 `wget localhost:9600`이 거부된다. 수집기는 IPv4(0.0.0.0)만 열므로
  점검은 `127.0.0.1`로. (Prometheus는 노드 이름→IPv4로 붙어 정상)
- **buildx 없음** — `docker build`가 legacy builder로 떨어지지만 이미지는 정상 빌드된다(경고 무시).
- **WSL 재시작 = veth 소실** — 베이스 랩이 `Active`로 떠 있으면 `up.sh`가 재배포하니 문제없다. → [[wsl-containerlab-keepalive]]
