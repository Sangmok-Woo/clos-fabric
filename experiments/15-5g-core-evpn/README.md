# 실험 15 — EVPN 패브릭 위의 5G 코어 (기획)

> [실험 목록](../README.md) · **상태 (2026-10-10):** 기획만 있다. 토폴로지·설정·스크립트는 아직 없고, 빈칸은 직접 채운다.

5G 코어(Open5GS)를 스파인-리프 위에 CP/UP 분리 구조로 올리고, 가상 단말(UERANSIM)의 데이터가 **어떤 포장을 거쳐 어떤 길로** 인터넷까지 가는지 잰다.
마지막에 제어부만 쿠버네티스로 옮겨 자가복구를 관찰한다.

**가설:**
1. 등록(제어)과 데이터(사용자)는 완전히 다른 길로 흐른다
2. GTP-U와 VXLAN이 겹치면 MTU 여유가 두 겹으로 줄어든다
3. 제어부는 쿠버네티스에 맡겨도 되지만 UPF는 고정 배치가 낫다

## 택배 회사 비유

| 5G 용어 | 택배 비유 | 랩 위치 |
|---|---|---|
| UE (단말) | 고객 | leaf1 |
| gNB (기지국) | 동네 집하장 | leaf1 |
| AMF | 본사 접수 창구 | leaf2 |
| SMF | 배송 계획 담당 | leaf2 |
| NRF | 사내 전화번호부 | leaf2 |
| AUSF/UDM/UDR + MongoDB | 고객 명부·신원 확인 | leaf2 |
| UPF | 물류센터 | leaf3 |
| DN 서버 | 배송지(인터넷) | leaf4 |

| 구간 | 누구 ↔ 누구 | 프로토콜 | 비유 |
|---|---|---|---|
| N2 | gNB ↔ AMF | NGAP over SCTP 38412 | 집하장 ↔ 본사 전화 |
| N3 | gNB ↔ UPF | GTP-U over UDP 2152 | 집하장 → 물류센터 트럭 |
| N4 | SMF ↔ UPF | PFCP over UDP 8805 | 본사 → 물류센터 작업지시서 |
| N6 | UPF ↔ DN | 일반 IP | 물류센터 → 배송지 |
| SBI | CP 부서끼리 | HTTP/2 | 사내 메신저 |

## 구성

```
            spine1        spine2
           /   |   \     /  |   \
      leaf1   leaf2   leaf3   leaf4
        |       |       |       |
   gNB + UE   CP 묶음   UPF    DN 서버
  (UERANSIM) (Open5GS) (Open5GS) (nginx 등)
```

전체 패브릭 대신 리프 4개만 쓴다 — 범인 후보를 줄이려고.

## 환경 확인 (2026-10-10, WSL 커널 6.6.114.1)

| 항목 | 결과 | 의미 |
|---|---|---|
| SCTP | `CONFIG_IP_SCTP=m`, `modprobe sctp` 성공 | N2가 붙는다. 컨테이너는 호스트 커널을 같이 쓰므로 WSL에서 켠다 |
| TUN | `CONFIG_TUN=m`, `/dev/net/tun` 있음 | UPF `ogstun`, UE `uesimtun0` |
| VXLAN / VRF | `=y` / `=m` | Phase 4·5 |
| 커널 GTP | 없음 | 상관없다. Open5GS UPF·UERANSIM은 GTP를 사용자 공간에서 처리 |
| 자원 | 8코어, 메모리 약 9GB | Phase 1~6은 여유. Phase 7(kind 추가)은 빠듯 |

## 미리 알아둘 함정

1. **Phase 4는 Phase 5 뒤로.** VXLAN 안의 GTP-U를 보려면 N3가 그 시점에 EVPN 오버레이를 타야 한다. VRF·L3VNI 없이 언더레이로 라우팅되면 캡처엔 GTP-U 한 겹만 보인다.
2. **containerlab 링크 MTU 기본값은 9500.** 그대로면 1500 근처에서 아무 일도 안 일어난다. 실측 전에 1500으로 낮춘다.
3. **kind와 containerlab의 도커가 다르다.** 기존 kind `shop`은 Docker Desktop, containerlab은 WSL dockerd. Phase 7은 WSL 안에 리눅스용 kind로 새 클러스터를 만들고 `ext-container` 링크로 leaf2에 붙인다.
4. **PFCP는 NAT를 싫어한다.** SMF 파드의 출발지가 SNAT되면 PFCP Node ID와 실제 주소가 어긋난다. AMF의 SCTP도 클러스터 밖으로 노출해야 한다. 가장 단순한 길은 AMF·SMF에 `hostNetwork: true`.
5. **UPF는 포워딩이 켜져 있다.** USER VRF에 UPF를 가리키는 경로가 하나라도 있으면 gNB → DN 핑이 UPF를 거쳐 통과한다. UE 대역은 **DN VRF에만** 광고한다.
6. Phase 6 ①의 방화벽 노드는 [실험 14](../14-acl-vs-firewall/README.md)의 `fwacl` 랩과 별개라 이 랩에 새로 넣어야 한다. `network-mode: none` 교훈도 같이 가져온다.

## 단계

진행 순서: 방화벽 랩(14) → Phase 0 → 1 → 2 → 3 → **5 → 4** → 6 → 7

### Phase 0 — 사전 준비
- WSL에서 `modprobe sctp`
- Open5GS·UERANSIM 커뮤니티 이미지(Gradiant 등) 확보, 버전 확인
- [주소·VRF 계획표](#주소vrf-계획표) 작성
- ✅ `lsmod | grep sctp` 출력, 계획표 완성

### Phase 1 — 올인원으로 붙이기
- Open5GS 전체(UPF 포함)를 leaf2 컨테이너 하나로, gNB+UE는 leaf1, DN 서버는 leaf4
- 가입자 등록: WebUI나 DB 스크립트로 IMSI·K·OPc 입력 (UE 설정값과 정확히 일치)
- ✅ UE에 `uesimtun0` 생성·IP 할당 → `ping -I uesimtun0 <DN 서버>` 성공
- 목적: 이해보다 "일단 된다"는 기준점

### Phase 2 — 등록 절차 해부
- N2 캡처 상태에서 UE 재접속
- 흐름: Registration Request → Authentication → Security Mode → Registration Accept → PDU Session Establishment
- N4에서 PFCP Session Establishment (SMF가 UPF에 작업지시서를 보내는 순간)
- ✅ 각 메시지를 비유표의 부서·구간에 대응시켜 정리

### Phase 3 — CP/UP 분리
- UPF만 leaf3으로 이사, SMF의 UPF 주소와 N3 주소 수정
- UE 대역의 귀갓길 (DN 서버가 UE 대역으로 응답할 경로)
  - 방법 A: UPF에서 NAT
  - 방법 B: UPF 노드에 FRR, UE 대역을 BGP로 패브릭에 광고 (실무형)
  - 둘 다 구성해서 비교
- ✅ 방법 B로 NAT 없이 UE ↔ DN 왕복, 리프 라우팅 테이블에서 UE 대역 확인

### Phase 5 — 구간별 VRF 분리
- CTRL VRF: N2, N4, SBI / USER VRF: N3 / DN VRF: N6
- VRF마다 L3VNI 하나씩, UPF는 여러 VRF에 다리를 걸친다
- ✅ UE 통신 정상 + gNB → DN 서버 직접 핑 실패(격리)

### Phase 4 — 터널 속 터널 (MTU 두 겹)
- leaf1↔spine 링크 캡처: VXLAN → UDP → GTP-U → UE의 원래 IP 패킷
- 오버헤드를 손으로 먼저 계산 (GTP-U: 외부 IP + UDP + GTP 헤더 + 확장헤더 / VXLAN: 약 50바이트)
- UE에서 `ping -I uesimtun0 -M do -s <크기>`로 경계 실측, 계산값과 비교
- ✅ 예측 경계·실측 경계·차이의 원인

### Phase 6 — 장애 시나리오

| # | 주입 | 예상 증상 |
|---|---|---|
| ① | 방화벽 노드에 TCP·UDP만 허용 | SCTP가 막혀 gNB–AMF 연결부터 실패, 등록 자체가 안 됨 |
| ② | N4(PFCP)만 차단 | 등록 성공, PDU 세션 실패 → `uesimtun0` 없음 |
| ③ | UPF 컨테이너 정지 | 등록 유지, 기존 데이터 중단, 새 세션 실패 |
| ④ | 가입자 OPc 한 글자 변경 | Authentication 단계에서 실패 |
| ⑤ | NRF 정지 후 다른 CP 부서 재시작 | 재시작한 부서가 다른 부서를 못 찾음, 기존 부서끼리는 당분간 동작 |
| ⑥ | 언더레이 MTU만 낮춤 | 작은 핑 성공, 큰 패킷·대용량 실패 |

하루 하나씩, 실험 노트 형식(시나리오명/주입/증상/추적 과정/원인·복구/한 줄 교훈)으로. 블라인드 회차는 위 표를 가리고 진행.

### Phase 7 — 제어부만 쿠버네티스로
- kind 클러스터를 leaf2에 연결, CP 부서를 파드로 (Open5GS 커뮤니티 헬름 차트, 버전 확인)
- UPF는 leaf3에 고정
- `kubectl delete pod <amf 파드>` 후 관찰: 기존 UE 데이터 통신 / 새 UE 등록 가능 여부 / 재기동~재등록 가능까지 시간
- ✅ 세 측정값 + UPF를 옮기지 않은 이유

## 주소·VRF 계획표

| 노드 | 리프 | 인터페이스 역할 | IP | VRF |
|---|---|---|---|---|
| gNB | leaf1 | N2 | | CTRL |
| gNB | leaf1 | N3 | | USER |
| AMF | leaf2 | N2 | | CTRL |
| SMF | leaf2 | N4 | | CTRL |
| UPF | leaf3 | N3 | | USER |
| UPF | leaf3 | N4 | | CTRL |
| UPF | leaf3 | N6 | | DN |
| DN 서버 | leaf4 | N6 | | DN |
| UE 대역 | UPF 할당 | — | | — |

## 설정 스켈레톤

UERANSIM gNB:

```yaml
mcc: '___'
mnc: '__'
tac: _
linkIp: ______      # gNB 자기 주소
ngapIp: ______      # N2 쪽
gtpIp:  ______      # N3 쪽
amfConfigs:
  - address: ______ # AMF N2 주소
    port: 38412
```

- UE 핵심 항목: `supi`, `key`, `op`, `opType`, `gnbSearchList`
- Open5GS 핵심 항목: AMF ngap 주소, SMF의 pfcp·upf 주소, UPF의 gtpu·pfcp 주소, UE 대역(session subnet)

## 관찰 기록표

| 관찰 | 캡처 위치 | 본 것 | 예상과 달랐던 점 |
|---|---|---|---|
| 등록 절차 순서 | N2 | | |
| PFCP 세션 수립 | N4 | | |
| 패킷 포장 겹수 | leaf1↔spine | | |
| MTU 경계 | UE | | |
| AMF 재시작 영향 | UE·N2 | | |

## 종료 기준

- [ ] CP/UP 분리 구조에서 UE → DN 통신
- [ ] UE 대역 BGP 광고로 NAT 없이 왕복
- [ ] Wireshark로 VXLAN 안의 GTP-U를 짚어서 설명
- [ ] MTU 경계를 계산으로 예측하고 실측으로 검증
- [ ] AMF 재시작 시 기존 통신과 신규 등록의 차이 설명
- [ ] 마무리 한 문장: "5G 코어에서 쿠버네티스에 맡겨도 되는 것과 맡기면 안 되는 것은 무엇인가"

## 분담

| 직접 | Claude |
|---|---|
| 주소·VRF 계획표, `topology.yml` | 스켈레톤, 이미지·설정 항목 안내 |
| Open5GS·UERANSIM 설정값 | 검수 |
| Wireshark 해석, 실험 노트 | Phase 6 블라인드 장애 주입(원할 때) |
