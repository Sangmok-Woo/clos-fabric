# k8s-ceph — Kubernetes + Ceph 스토리지망

> **한 줄** — [elice-infra](https://github.com/Sangmok-Woo/elice-infra)에서 설계한 K8s·Ceph 스토리지망 분리를
> 이 패브릭(스파인 2 / 리프 4)에 옮겨, 같은 요구사항이 다른 크기의 패브릭에서도 그대로 성립하는지 확인한다.

이 디렉터리는 베이스 패브릭 위에 K8s 워커 3대와 Ceph 노드 3대를 얹은 **독립 하위 프로젝트**다. 베이스 설정(`../configs`)은
고치지 않고 그대로 재사용하며, 오버레이는 배포 뒤에 덧붙인다. 토폴로지 이름이 `clos`라 컨테이너가 `clab-clos-*`가 되어
기존 스크립트(`check.sh`, `failover.sh` 등)도 그대로 동작한다. 베이스·모니터링과 같은 이름이므로 셋 중 하나만 떠 있는다.

## 실행

```bash
cd k8s-ceph
./up.sh            # 이미지 빌드 → 배포 → 리프 오버레이 + EVPN (약 1분)
./test.sh          # 요구사항 점검 25개 (장애 시험 포함). ./test.sh quick 은 장애 시험을 뺀 22개
./down.sh          # 철거. 베이스로 돌아가려면 ../scripts/deploy.sh up
```

컨테이너 18대(베이스 12 + 워커 3 + Ceph 3), WSL2 4GB에서 돌렸다.

## 구성

```
           spine1 (65001)            spine2 (65002)
              │  eBGP + EVPN 중계 (next-hop 유지)  │
   ┌──────────┼──────────────┬──────────────┬─────┘
 leaf1        leaf2          leaf3          leaf4
 wrk1         wrk2 ceph1     wrk3 ceph2     ceph3
```

| 망 | VLAN / L2VNI | VRF / L3VNI | 대역 | MTU | 붙는 곳 |
|---|---|---|---|---|---|
| K8S-NODE | 110 / 10110 | PROD / 50010 | 10.10.16.0/24 | 1500 | 워커 eth1 |
| STORAGE (Ceph public) | 120 / 10120 | STORAGE / 50020 | 10.10.20.0/24 | 9000 | 워커 eth2, Ceph eth1 |
| REPL (Ceph cluster) | 130 / 10130 | REPL / 50030 | 10.10.24.0/24 | 9000 | Ceph eth2 |

- 리프 포트는 eth11~eth14만 쓴다. 베이스(eth3·eth4)와 실험이 쓰는 eth5는 비워 둔다
- 게이트웨이는 애니캐스트(모든 리프가 `.1`과 같은 MAC), VTEP은 베이스 루프백 `10.255.1.N`
- RT는 공통값 `65000:VNI`. eBGP 패브릭에서는 자동 RT(`내 AS:VNI`)가 리프마다 달라 서로 import하지 않는다
- 워커 FRR이 리프와 BGP로 피어링한다(운영에서는 Cilium BGP Control Plane). 리프는 listen range로 받고,
  VIP(10.10.32.0/24)와 Pod 대역(10.20.0.0/16의 /24)만 받는다. 리프 쪽에서는 아무것도 내보내지 않는다
- wrk2·wrk3이 Ingress VIP `10.10.32.10/32`를 광고 → leaf1에서 두 랙으로 ECMP

## elice-infra와 다른 점

| | elice-infra | 여기 |
|---|---|---|
| 패브릭 | 스파인 2 / 리프 6 (랙당 리프 2대) | 스파인 2 / 리프 4 (랙당 1대) |
| 언더레이 | BGP unnumbered | 베이스 그대로 (/31 numbered) |
| 서버 연결 | 리프 두 대에 bond | 리프 한 대에 NIC 두 장 |
| 노드 수 | ctrl 3 + wrk 5 + Ceph 4 | wrk 3 + Ceph 3 |
| 방화벽·인터넷·배스천 | 있음 (구역 간 통신은 방화벽만) | 뺐다. 스토리지망 분리만 옮겼다 |

## 점검 항목 (`test.sh`)

1. **세션** — 리프·스파인 EVPN 세션, 베이스 서버 h1 → h4 통신 (기존 랩이 깨지지 않았는지)
2. **오버레이** — 랙을 넘는 같은 서브넷, Ceph public·cluster 점보 9000(`ping -M do -s 8972`), 워커 → Ceph가 스토리지 NIC로 직행, 노드망은 1500
3. **분리** — 워커 → Ceph cluster 불가, 워커 노드망 → Ceph public 라우팅 불가, 베이스 서버 → K8s·Ceph 대역 불가
4. **K8s BGP** — 워커 세션, VIP ECMP, 엉뚱한 대역(8.8.8.0/24) 광고를 리프가 거부
5. **장애** — Ceph 복제 중 그 트래픽이 지나는 스파인의 leaf2·leaf4 링크 끊김(200/200 수신), VIP 노드 하나 철회 시 경로가 남은 노드로 줄어듦

2026-10-22 실측: **25 / 25 PASS**.

## 패킷 캡처

망마다 ping을 흘려 서버 포트와 리프 업링크에서 캡처하고, VLAN 태그가 VNI로 바뀌는 모습, 점보 프레임의 바깥 길이(9050B),
라우팅 흐름의 L3VNI/L2VNI 비대칭, EVPN Type-5 경로 해독을 정리했다. → [packets/2026-10-22 2부](../packets/2026-10-22/README.md#2부--k8s-ceph-경로별-패킷-모양과-흐름)

## 파일

| 파일 | 하는 일 |
|---|---|
| `clos-k8s.clab.yml` | 베이스 노드 + 워커·Ceph 6대. 서버 NIC(VLAN 서브인터페이스)는 `exec`로 설정 |
| `leaf/overlay.sh` | 리프 안에서 실행. VRF 3개, VLAN 브리지 3개, VXLAN 장치 |
| `leaf/frr-overlay.conf` | 리프 EVPN·VRF BGP 설정 틀. `up.sh`가 AS·router-id를 채워 `vtysh -f`로 덧붙인다 |
| `configs/wrkN/frr.conf` | 워커의 BGP 스피커 설정 |
| `node/Dockerfile` | 서버 공용 이미지 (FRR + iputils). busybox ping에는 `-M`이 없어 점보 차단을 확인할 수 없다 |
