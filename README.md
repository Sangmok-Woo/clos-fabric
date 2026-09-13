<div align="center">

# clos-fabric

**컨테이너 12대로 세운 spine-leaf 데이터센터 패브릭 —
일부러 고장 내고, 끊긴 시간을 실측하고, 튜닝으로 줄인 기록**

![FRR](https://img.shields.io/badge/FRRouting-10.2.1-4f46e5)
![containerlab](https://img.shields.io/badge/containerlab-0.75.0-0d9488)
![underlay](https://img.shields.io/badge/underlay-eBGP%20%2B%20ECMP%20%2B%20BFD-2563eb)
![overlay](https://img.shields.io/badge/overlay-VXLAN%2FEVPN-7c3aed)
![runs on](https://img.shields.io/badge/runs%20on-Docker%20%2F%20WSL2-475569)

<img src="assets/topology.svg" width="860" alt="spine-leaf 토폴로지 — h1→h4 트래픽이 ECMP로 두 스파인에 갈라지고, v1↔v3은 VXLAN으로 랙을 넘는다">

</div>

## 30초 요약

- **무엇을**: 현대 데이터센터의 표준 구조(Clos/spine-leaf)를 노트북 위 FRR 컨테이너 12대(스파인 2 + 리프 4 + 서버 6)로 재현했다.
- **어떻게**: RFC 7938 방식의 eBGP 언더레이(장비마다 AS 하나) → ECMP 부하분산 → 장애 주입·수렴 시간 실측 → BFD 튜닝 → VXLAN/EVPN 오버레이 순으로 쌓았다.
- **왜**: "구성해봤다"가 아니라 **숫자로 검증했다**. 아래 표의 값은 전부 이 랩에서 직접 측정한 것이다.

## 실측 결과

| 실험 | 조건 | 결과 |
|---|---|---|
| 링크 다운 복구 | 케이블 단선 (인터페이스 다운 감지) | **0.2초** |
| 스파인 무응답 복구 | BFD 없음 — BGP 타이머(3/9초)에 의존 | 7.6초 |
| 스파인 무응답 복구 | **BFD 300ms×3 적용** | **0.8초 (약 10배 개선)** |
| ECMP 분산 (흐름 40개) | 해시가 IP만 볼 때 → L4 포트까지 볼 때 | 41:1 (몰빵) → **12:30 (분산)** |
| 랙을 넘는 L2 | VXLAN VNI 10010 + BGP EVPN | v1 ↔ v3 통신, 원격 MAC을 leaf3 VTEP으로 학습 |

세 가지 교훈이 숫자로 남았다:
**① 장애 감지는 "케이블이 뽑혔나"와 "상대가 조용히 죽었나"가 전혀 다르고, 그 간극을 BFD가 메운다.**
**② ECMP는 해시 입력에 무엇을 넣느냐가 전부다.**
**③ L2를 랙 너머로 늘리고 싶으면 케이블이 아니라 터널(VXLAN)로 푼다.**

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

## 문서

| 문서 | 무엇을 적나 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **설계 기준과 이유** — 왜 spine-leaf·eBGP인가, 주소·AS·포트가 전부 계산식인 이유, 운영 원칙 |
| [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md) | **실험과 실측** — 측정 방법, ECMP·수렴·BFD·EVPN의 숫자와 함정, 검증으로 내린 결정 2건 |
| [CHANGELOG.md](CHANGELOG.md) | 무엇이 언제 바뀌었나 — 검증·결정·변경의 시간 순 기록 |
