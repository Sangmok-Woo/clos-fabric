<div align="center">

<img src="assets/logo.svg" width="430" alt="clos-fabric">

**일부러 고장 내고, 끊긴 시간을 실측하고, 튜닝으로 줄인
spine-leaf 데이터센터 패브릭 — 컨테이너 12대**

*A hands-on Clos fabric lab: eBGP underlay, ECMP, failure convergence measured in numbers,
BFD tuning, and a VXLAN/EVPN overlay — fully reproducible with scripts.*

![FRR](https://img.shields.io/badge/FRRouting-10.2.1-4f46e5)
![containerlab](https://img.shields.io/badge/containerlab-0.75.0-0d9488)
![underlay](https://img.shields.io/badge/underlay-eBGP%20%2B%20ECMP%20%2B%20BFD-2563eb)
![overlay](https://img.shields.io/badge/overlay-VXLAN%2FEVPN-7c3aed)
![runs on](https://img.shields.io/badge/runs%20on-Docker%20%2F%20WSL2-475569)

<br>

[**설계와 이유**](docs/DESIGN.md) · [**실험과 실측**](docs/EXPERIMENTS.md) · [**빠른 시작**](#빠른-시작) · [**Roadmap**](#roadmap) · [**변경 기록**](CHANGELOG.md)

<img src="assets/topology.svg" width="860" alt="spine-leaf 토폴로지 — h1→h4 트래픽이 ECMP로 두 스파인에 갈라지고, v1↔v3은 VXLAN으로 랙을 넘는다">

<table>
<tr>
<td align="center" width="33%">
<h3>💥 고장은 일부러 낸다</h3>
<sub>케이블 단선과 "조용한 먹통"을 주입하고<br>끊긴 시간을 0.2초 단위로 실측 —<br>BFD 튜닝으로 <b>8.8초 → 1.2초</b></sub>
</td>
<td align="center" width="33%">
<h3>⚖️ 분산은 숫자로 검증</h3>
<sub>"경로 2개"와 "반씩 간다"는 다르다 —<br>흐름 40개를 링크별로 계수해<br>해시 정책의 <b>몰빵 vs 분산</b>을 증명</sub>
</td>
<td align="center" width="33%">
<h3>🕸️ L2는 터널로 편다</h3>
<sub>랙이 달라도 같은 서브넷 —<br>VXLAN/EVPN으로 MAC을 BGP에 태우고<br><b>eBGP 특유의 함정 3개</b>를 기록</sub>
</td>
</tr>
</table>

</div>

## 30초 요약

- **무엇을**: 현대 데이터센터의 표준 구조(Clos/spine-leaf)를 노트북 위 FRR 컨테이너 12대(스파인 2 + 리프 4 + 서버 6)로 재현했다.
- **어떻게**: RFC 7938 방식의 eBGP 언더레이(장비마다 AS 하나) → ECMP 부하분산 → 장애 주입·수렴 시간 실측 → BFD 튜닝 → VXLAN/EVPN 오버레이 순으로 쌓았다.
- **왜**: "구성해봤다"가 아니라 **숫자로 검증했다**. 아래 표의 값은 전부 이 랩에서 직접 측정한 것이다.

<details>
<summary><b>English summary</b></summary>
<br>

A 12-container Clos (spine-leaf) datacenter fabric built with FRRouting and containerlab: 2 spines, 4 leaves, 6 servers. The underlay follows RFC 7938 — eBGP with one private AS per device, ECMP enabled via <code>multipath-relax</code>. On top of it I injected failures and measured convergence: a link cut converges in <b>0.2s</b>, a silently frozen spine blackholes traffic for <b>7.6–8.8s</b> (hold-timer bound), and adding <b>BFD (300ms×3)</b> cuts that to <b>0.8–1.2s</b>. ECMP load-sharing was measured per-link with 40 UDP flows, showing why <code>fib_multipath_hash_policy=1</code> is mandatory. A VXLAN/EVPN overlay stretches one L2 segment across racks, including the eBGP-specific pitfalls (route-target mismatch, next-hop rewriting). Design rationale lives in <a href="docs/DESIGN.md">docs/DESIGN.md</a>, experiments and evidence in <a href="docs/EXPERIMENTS.md">docs/EXPERIMENTS.md</a>. Everything is reproducible with the scripts in this repo.

</details>

## 실측 결과

| 실험 | 조건 | 결과 |
|---|---|---|
| 링크 다운 복구 | 케이블 단선 (인터페이스 다운 감지) | **0.2초** |
| 스파인 무응답 복구 | BFD 없음 — BGP 타이머(3/9초)에 의존 | 7.6초 |
| 스파인 무응답 복구 | **BFD 300ms×3 적용** | **0.8초 (약 10배 개선)** |
| ECMP 분산 (흐름 40개) | 해시가 IP만 볼 때 → L4 포트까지 볼 때 | 41:1 (몰빵) → **12:30 (분산)** |
| 랙을 넘는 L2 | VXLAN VNI 10010 + BGP EVPN | v1 ↔ v3 통신, 원격 MAC을 leaf3 VTEP으로 학습 |

> 첫 측정과 재측정(8.8초/1.2초)의 차이, 측정 방법, 전체 출력은 [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md)에 있다.

### 하이라이트 — 같은 장애, BFD 전후

<div align="center">
<img src="assets/demo.svg" width="840" alt="failover.sh 실행 터미널 — BFD 없이 8.8초, BFD 적용 후 1.2초">
</div>

위 터미널은 실제 실행 출력을 그대로 재생한 것이다. 스파인을 조용히 얼리는 같은 장애를 BFD 적용 전후로 두 번 주입했다 — 전체 출력과 타임라인 해설은 [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md).

## 검증의 흐름

1. **언더레이** — 리프↔스파인 8링크 전부 eBGP(/31, 장비당 AS 하나). `maximum-paths` + `multipath-relax`로 ECMP 확보
2. **부하분산** — 커널 해시 정책 0/1을 바꿔가며 링크별 분산을 tcpdump로 계수
3. **장애와 수렴** — 링크 다운 / 스파인 freeze를 주입하고 끊긴 시간을 측정, BFD로 개선
4. **오버레이** — VXLAN + BGP EVPN(Type-2/3)으로 랙이 다른 두 서버를 같은 L2로
5. **확장 검증** — 동적 이웃(listen range)은 검증 후 **기각**, BGP unnumbered는 fe80 넥스트홉까지 확인 후 **채택** ([CHANGELOG](CHANGELOG.md))

여기에 매일 하나씩 고장 내고 복구하는 **30일 장애 훈련**(`scripts/day.sh`)을 얹어 운영 감각을 유지한다.

> 이 브랜치(main)는 정리된 기록이다. 진행 중인 작업·운영 절차·훈련 일지는 [`lab` 브랜치](https://github.com/Sangmok-Woo/clos-fabric/tree/lab)에 있다.

## 빠른 시작

준비물: 리눅스 + Docker + [containerlab](https://containerlab.dev) (이 랩은 WSL2 Ubuntu에서 개발·측정했다. 컨테이너 12대, 메모리 500MB 남짓)

```bash
git clone https://github.com/Sangmok-Woo/clos-fabric && cd clos-fabric
./scripts/deploy.sh up      # 12대 기동, BGP 세션 8개 자동 수립
./scripts/check.sh          # 세션·ECMP·서버 간 통신 점검
```

## 스크립트

| 명령 | 하는 일 |
|---|---|
| `./scripts/deploy.sh up\|down\|redeploy` | 랩 기동 / 철거 |
| `./scripts/check.sh` | BGP 세션·ECMP·서버 간 통신·BFD 상태 점검 |
| `./scripts/ecmp-hash.sh` | 해시 정책 0/1 에서 링크별 트래픽 분산 측정 |
| `./scripts/failover.sh link\|freeze` | 장애 주입 후 끊긴 시간 측정 |
| `./scripts/bfd-apply.sh on\|off` | BFD 적용/해제 |
| `./scripts/evpn-apply.sh` | VXLAN + BGP EVPN 구성 및 검증 |
| `./scripts/day.sh` | 30일 장애 훈련 진행기 — 오늘의 고장 / 정답·해설·자동복구 |
| `./scripts/listen-range-test.sh` | 스파인 이웃을 동적(listen range)으로 바꿔보고 원복 |
| `./scripts/unnumbered-test.sh` | spine1↔leaf1 한 링크만 BGP unnumbered로 바꿔 fe80 넥스트홉 확인 후 원복 |
| `./scripts/in.sh <노드> <명령>` | 호스트의 도구(tcpdump 등)를 컨테이너 네트워크 안에서 실행 |

## Roadmap

- [ ] **설정 생성기** — `fabric.yml`의 숫자(스파인 수·리프 수)만 바꾸면 토폴로지와 FRR 설정 전체가 재생성되게. 주소·AS·포트가 전부 계산식이라([DESIGN §3~4](docs/DESIGN.md)) 코드로 옮기기만 하면 된다
- [ ] **BGP unnumbered 전면 전환** — 검증은 끝났고([EXPERIMENTS §4](docs/EXPERIMENTS.md)), 재배포 때 링크 IP를 걷어낸다
- [ ] **모니터링** — frr_exporter + Prometheus로 세션 수·경로 수를 긁고, 기대값은 토폴로지에서 계산해 대조
- [ ] **MTU** — VXLAN은 50바이트를 더 쓴다. 언더레이를 점보 프레임(9216)으로 올리고 경계에서 MSS를 확인
- [ ] **쿠버네티스 연동** — Calico/Cilium이 리프와 BGP 피어링해 파드 네트워크를 패브릭에 직접 태우기

## 문서

| 문서 | 무엇을 적나 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **설계 기준과 이유** — 왜 spine-leaf·eBGP인가, 주소·AS·포트가 전부 계산식인 이유, 운영 원칙 |
| [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md) | **실험과 실측** — 측정 방법, ECMP·수렴·BFD·EVPN의 숫자와 함정, 검증으로 내린 결정 2건 |
| [CHANGELOG.md](CHANGELOG.md) | 무엇이 언제 바뀌었나 — 검증·결정·변경의 시간 순 기록 |

---

<div align="center">
<sub>FRRouting + containerlab으로 노트북 위에 세운 랩 — 이 README의 모든 수치는 저장소의 스크립트로 재현할 수 있다.</sub>
</div>
