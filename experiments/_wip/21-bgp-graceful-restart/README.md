# 실험 21 — BGP Graceful Restart: 컨트롤 플레인이 재시작하는 동안 데이터 플레인

> [실험 목록](../../README.md) · 실행 기록 [capture/run-output.txt](capture/run-output.txt)

[실험 07](../../_completed/07-spine-freeze-bfd/README.md)에서는 스파인이 통째로 멈추면 BGP가 hold timer(9초)로, BFD가 0.9초로 알아챘다.
이번에는 반대쪽 경우다. 스파인의 **bgpd만** 죽었다가 살아난다. 커널 FIB는 멀쩡하니 패킷은 계속 지나갈 수 있다.
GR(Graceful Restart)은 이웃에게 "잠깐 재시작하는 것이니 내 경로를 지우지 말라"고 부탁하는 기능이다.
이 장에서는 GR이 bgpd 재시작의 끊김을 실제로 0으로 만드는지 잰다. 그다음 GR이 진짜 장애(장비 freeze)를 얼마나 오래 가리는지, BFD가 그 문제를 풀어 주는지 본다.

본 패브릭은 다른 실험이 쓰고 있어서, 같은 규칙(스파인 2 + 리프 2, 장비마다 AS 하나, eBGP, `timers 3 9`)으로 작은 랩 `grlab`을 따로 세웠다.

## 장애 구성

```
               ┌── eth1 ───── spine1 (AS 65001) ──┐
   h1 ── leaf1                                     leaf2 ── h2     h1 → h2 ping 0.01초 간격
 (65011)       └── eth2 ───── spine2 (AS 65002) ──┘ (65012)
                    ╳  A·B·D2·D3: 리프의 eth2 를 내려 spine1 한 길만 남김
```

| Phase | GR | BFD | 경로 | 넣는 장애 |
|---|---|---|---|---|
| A | 없음 (FRR 기본 helper만) | 없음 | 단일 (spine1) | spine1 bgpd `kill -9` → watchfrr가 약 5초 뒤 다시 띄움 |
| B1 | `bgp graceful-restart` (F 비트 0) | 없음 | 단일 | 같은 `kill -9` |
| B2 | + `preserve-fw-state` (F 비트 1) | 없음 | 단일 | 같은 `kill -9` |
| B3 | + bgpd `-K` (재시작 모드로 기동) | 없음 | 단일 | 같은 `kill -9` |
| C | B3과 같음 | 없음 | ECMP | ping이 타는 스파인 freeze (`ip_forward=0` + `docker pause`, 07과 같음) |
| D1 | B3과 같음 | 300ms × 3 | ECMP | C와 같은 freeze |
| D2 | B3과 같음 | 300ms × 3 | 단일 | B와 같은 `kill -9` |
| D3 | B3과 같음 | + `check-control-plane-failure` | 단일 | `kill -9` |
| D4 | B3과 같음 | + `check-control-plane-failure` | ECMP | freeze |

- GR은 네 라우터 모두에 켠다. 재시작하는 쪽(spine1)과 돕는 쪽(helper, 리프)이 같은 설정을 쓴다. `restart-time`은 기본 120초를 **30초**로 줄였다(C·D4가 짧게 끝나게). stalepath-time은 기본 360초 그대로다.
- **단일 경로**로 둔 이유: spine2가 살아 있으면 리프가 ECMP로 spine2만 쓰면서 GR 효과를 가린다. 재시작 동안 대체 경로가 없는 경우가 GR이 필요한 경우다.
- **Phase마다 랩을 새로 띄운다.** 그리고 리프 bgpd가 기동한 지 130초가 지난 뒤 장애를 넣는다(이유는 [⑥](#패킷-흐름--리프가-막-기동했으면-gr이-반쯤만-된다)).
- watchfrr의 재시작 간격은 `--min-restart-interval 2 --max-restart-interval 4`로 고정했다([configs/docker-start](configs/docker-start)). 기본값은 20분 안에 재시작이 반복되면 간격을 60→120→240초로 늘린다. 첫 실행에서 bgpd가 30초 넘게 돌아오지 않아 고쳤다.
- 캡처: h1:eth1(ICMP 0.01초 간격), leaf1·leaf2의 대상 스파인 쪽 링크(tcp 179, udp 3784), leaf1·스파인 커널 경로 변화(`ip -ts monitor route`), 네 라우터의 frr.log(`debug bgp neighbor-events / graceful-restart / bfd`).

## 예측 (실행 전에 적은 것)

| Phase | 예측 | 실제 |
|---|---|---|
| A | 리프가 TCP 종료를 보자마자 경로를 지우고 spine1 zebra도 커널 경로를 지운다. 끊김 3~5초 | **7.43초**. watchfrr가 5초 기다리는 것을 몰랐다 |
| B | 리프는 stale로 남기고 spine1 zebra도 커널 경로를 남긴다. 끊김 0 | 설정에 따라 갈렸다. GR만: **1.22초**, `preserve-fw-state`까지: **0** |
| C | hold timer(9초) + restart-time(30초). 약 37~39초 | **38.29초** (맞음) |
| D1 | BFD Down → Hard Reset이라 stale을 남기지 않는다. 약 1.1초 | **0.95초** (맞음) |
| D2 | bfdd는 따로 도는 데몬이니 BFD는 Up 그대로. B처럼 0 | **2.15초**. BFD가 GR을 깼다 |

예측표는 처음에 Phase B를 하나로 적었다. 돌려 보니 B 안에서 결과가 갈려 B1~B3으로 나눴다. D3·D4는 D2 결과를 본 뒤 더한 것이라 예측이 없다.

## 실행

```bash
cd /root/labs/clos-fabric/experiments/_wip/21-bgp-graceful-restart   # sync.sh 로 윈도우 원본을 복사한 실행 사본
./up.sh            # grlab 띄우기 (clab-grlab-*, 관리망 172.30.21.0/24)
./run.sh           # A B1 B2 B3 C D1 D2 D3 D4, Phase 마다 랩을 새로 띄운다 (약 30분)
./run.sh B2 D2     # 고른 Phase 만
./down.sh          # 지우기
```

## 숫자

| Phase | 끊김 (응답 공백) | 응답 없는 요청 | 무엇이 끊김을 정했나 |
|---|---|---|---|
| A GR 없음 | **7.43초** (T0+0.01 ~ +7.43) | 738 | bgpd 재기동 5.2초 + OPEN 1초 + 첫 UPDATE 1.1초 |
| B1 GR, F 비트 0 | **1.22초** (T0+6.17 ~ +7.39) | 120 | 새 OPEN의 F 비트 0을 보고 리프가 stale을 지움 → UPDATE까지 |
| B2 GR + preserve-fw-state | **0** | 0 | |
| B3 B2 + bgpd `-K` | **0** | 0 | (B2와 차이 없음) |
| C GR, freeze | **38.29초** (T0 ~ +38.28) | 3811 | hold timer 8.22초 + restart-time 30초 |
| D1 GR + BFD, freeze | **0.95초** | 94 | BFD Down T0+0.880 |
| D2 GR + BFD, kill -9 | **2.15초** (T0+6.14 ~ +8.30) | 213 | 세션이 다시 붙는 순간 BFD가 한 번 Down → Hard Reset |
| D3 D2 + check-control-plane-failure | **2.16초** | 213 | D2와 같음 |
| D4 D1 + check-control-plane-failure, freeze | **17.07초** (T0+15에 복구해서 끝남) | 1696 | BFD Down을 무시함 → hold timer → stale. 복구하지 않았으면 C처럼 ~38초였을 것 |

공통 시각(bgpd `kill -9` Phase): 새 bgpd 기동 T0+5.0~5.2, 새 OPEN T0+6.06~6.17, End-of-RIB 교환 T0+7.2~7.3.
OPEN 뒤 첫 UPDATE까지 1.1초는 FRR이 세션이 붙은 뒤 UPDATE를 모아 보내는 시간이다. A·B1의 끊김이 OPEN이 아니라 이때 끝난다.

## 패킷 흐름 ① GR 없음 — 양쪽이 동시에 지운다 (A)

```
T0 +0.002  spine1 → leaf1  TCP FIN          ← kill -9: 커널이 소켓을 닫는다
T0 +0.014  spine1 커널: Deleted 172.16.11.0/24, 172.16.12.0/24   ← zebra가 bgpd 경로를 바로 지움
T0 +0.073  leaf1 커널:  Deleted 172.16.12.0/24                   ← leaf1도 "Peer closed the session"
T0 +5.15   spine1 새 bgpd
T0 +6.169  OPEN  Restart Flags: [R], Restart Time 120s  (GR 능력은 있지만 IPv4 F 비트가 없다 = helper만)
T0 +7.270  End-of-RIB
T0 +7.381  spine1 커널 경로 복구 / +7.431 leaf1 복구 → 끊김 7.43초
```

## 패킷 흐름 ② GR — F 비트 하나가 1.2초를 정한다 (B1 vs B2)

B1, B2 모두 kill 직후는 같다. leaf1은 `Down NSF peer closed the session`을 찍고 restart 타이머 30초를 건다.
경로는 `(stale)`로 남고 커널에도 그대로 있다. spine1 zebra도 커널 경로를 지우지 않았다.
`show bgp` 화면에서는 이렇게 보인다(T0+1.5).

```
65001 65012, (stale)
  10.1.1.0(spine1) from spine1(10.1.1.0) (0.0.0.0)
    Time until Graceful Restart stale route deleted: 28
```

갈린 곳은 새 bgpd가 보낸 OPEN이다(leaf1-ctl.pcap, tcpdump -v).

```
B1  T0+6.117  10.1.1.0 > 10.1.1.1  Restart Flags: [R], Restart Time 30s
                                   AFI IPv4 (1), SAFI Unicast (1)                                ← F 비트 없음
    T0+6.178  leaf1 커널: Deleted 172.16.12.0/24        ← OPEN 61ms 뒤
    T0+7.379  leaf1 커널: 172.16.12.0/24 다시 설치        → 끊김 1.22초

B2  T0+6.098  10.1.1.0 > 10.1.1.1  Restart Flags: [R], Restart Time 30s
                                   AFI IPv4 (1), SAFI Unicast (1), Forwarding state preserved: yes ← F 비트 1
    T0+7.249  End-of-RIB 교환. 커널 경로 변화 없음    → 끊김 0
```

RFC 4724는 helper에게 이렇게 정한다. 재시작한 쪽의 새 OPEN에 그 주소 패밀리의 F 비트(포워딩 상태를 지켰다)가 없으면 stale 경로를 바로 지운다.
FRR은 `bgp graceful-restart`만으로는 F 비트를 세우지 않는다. `bgp graceful-restart preserve-fw-state`를 따로 줘야 한다.
그래서 "GR을 켰다"만으로는 재시작 구간(5초)은 넘기지만, 세션이 다시 붙는 순간 1.2초가 끊긴다.

B3(bgpd `-K`)은 B2와 숫자가 같았다. 이번 조건에서는 `-K` 없이도 재시작한 bgpd가 리프 둘의 End-of-RIB을 기다렸다(spine1 로그 `EOR REQ 2, EOR RCV 2`). 그동안 zebra는 커널 경로를 그대로 두었다.

## 패킷 흐름 ③ 함정 — 진짜로 죽은 장비를 GR이 30초 더 살려 둔다 (C)

ECMP 상태에서 ping이 타던 spine2를 07처럼 얼렸다. leaf1의 BGP 기록(T0 기준):

```
T0 +8.216  leaf1 → spine2  NOTIFICATION Hold Timer Expired (4)       ← 07과 같은 hold timer 감지
           leaf1 log: graceful restart timer started for 30 sec       ← 그런데 helper가 된다
T0 +9.227  leaf1 → spine2  OPEN   (얼린 spine2 커널이 SYN-ACK는 해 준다. bgpd는 대답 없음)
T0+18.227  Hold Timer Expired  →  T0+19.228 OPEN  →  T0+28.228 Hold Timer Expired ...
T0+38.216  leaf1 log: graceful restart timer expired
T0+38.277  leaf1 커널: 172.16.12.0/24 via 10.1.1.0 (spine1만)          → 끊김 38.29초
```

T0+12에 leaf1 커널을 보면 죽은 spine2가 ECMP 넥스트홉에 그대로 있다.

```
172.16.12.0/24 proto bgp   nexthop via 10.1.2.0 dev eth2   ← (stale), 죽은 spine2
                           nexthop via 10.1.1.0 dev eth1
```

hold timer 만료는 RFC 8538(N 비트) 이후 "그래도 GR로 다룬다"가 기본이다. 그래서 07에서 7.6초였던 같은 장애가 **38초**가 됐다. 그동안 살아 있는 spine1이 옆에 있었다.
restart-time을 기본값(120초)으로 두었다면 약 128초다.

## 패킷 흐름 ④ BFD는 freeze를 끊지만, 재시작도 끊는다 (D1 vs D2)

D1(freeze)은 07의 BFD 장과 같다. `T0+0.880 BFD Down (Control Detection Time Expired)`이 나가고 같은 순간 `NOTIFICATION(Hard Reset) Cease/BFD Down`이 나간다.
Hard Reset은 "GR 하지 말라"는 뜻이라 stale을 남기지 않는다. T0+0.950에 커널이 spine1만 남겼다. 끊김은 0.95초다. GR이 켜져 있어도 C의 함정이 없어졌다.

D2(같은 설정에서 bgpd `kill -9`)는 기대와 달랐다.

```
T0 +0.002  spine1 → leaf1  TCP FIN → leaf1 "NSF peer closed the session", stale 유지
T0 +0.004  spine1 → leaf1  BFD State Down (Neighbor Signaled Session Down)
           ← bfdd 는 살아 있지만, 클라이언트(bgpd)가 사라지자 세션을 지우며 Down 을 알린다
           ← leaf1 의 BGP 세션은 이미 내려가 있어서 영향 없음. 데이터는 계속 흐른다
T0 +6.073  BFD Up, OPEN 교환, 세션 Up
T0 +6.074  spine1 log: bgp_peer_bfd_update_source: address [0.0.0.0->10.1.1.1] to [10.1.1.0->10.1.1.1]
T0 +6.075  spine1 → leaf1  BFD State Down (Neighbor Signaled Session Down)   ← 출발지 주소가 바뀌어 BFD 세션을 새로 만듦
T0 +6.075  leaf1 → spine1  NOTIFICATION(Hard Reset) Cease/BFD Down
T0 +6.146  leaf1 커널: Deleted 172.16.12.0/24      ← Hard Reset이라 stale까지 지움
T0 +7.076  BFD Up, 세션 다시 Up
T0 +8.282  leaf1 커널: 경로 다시 설치                 → 끊김 2.15초
```

재시작한 bgpd는 BFD 세션을 출발지 주소 없이(0.0.0.0) 먼저 등록한다. BGP 세션이 붙은 뒤 실제 주소로 바꾸는데, 그때 BFD 세션이 한 번 내려간다.
리프는 막 붙은 세션의 BFD Down을 진짜 장애로 보고 Hard Reset을 보낸다. GR로 지켜 둔 경로까지 그 순간 지워진다.
FRR 10.2.1에서 본 동작이다. 다른 버전에서는 다를 수 있다.

## 패킷 흐름 ⑤ check-control-plane-failure는 반대로 작동했다 (D3, D4)

`neighbor FABRIC bfd check-control-plane-failure`는 "BFD가 컨트롤 플레인과 운명을 같이하는지(C 비트)를 보고 판단하라"는 옵션이다. FRR bfdd는 C 비트를 0으로 보낸다(로그 `CPI bit no`).

- D3(kill -9): T0+0.004의 Down은 `BFD DOWN message ignored in the process of graceful restart when C bit is cleared`로 무시됐다. 그러나 끊김을 만든 T0+6.023의 Down(세션이 붙은 직후)은 GR 과정 밖이라 그대로 Hard Reset이 됐다. **2.16초**로 D2와 같다.
- D4(freeze): T0+0.873의 진짜 장애 Down도 같은 문구로 **무시됐다**. 결국 T0+7.957 hold timer로 알고, 그 뒤 stale을 30초 지키는 C의 경로로 갔다. 이 실행은 T0+15에 freeze를 풀어서 17.07초에 끝났다. 풀지 않았다면 C처럼 약 38초였을 것이다(재지 않은 추정).

이 옵션은 D2의 문제(재접속 순간의 BFD Down)를 막지 못했다. 그리고 D1에서 BFD가 해 주던 일(freeze 감지)은 없앴다.

## 패킷 흐름 ⑥ 리프가 막 기동했으면 GR이 반쯤만 된다

첫 두 실행에서는 B2·B3도 1.25초씩 끊겼다([capture/run2-output.txt](capture/run2-output.txt)). 그때와 최종 실행의 차이는 리프 OPEN의 R 비트 하나였다.

| | 리프 bgpd 기동 후 | 리프 OPEN의 R 비트 | spine1 `EOR REQ` | spine1 커널 | 끊김 |
|---|---|---|---|---|---|
| run2 B2 | 약 1분 | **SET** | 0 | T0+6.210 Deleted (OPEN 21ms 뒤) | 1.25초 |
| 최종 B2 | 130초 넘게 | NOT-SET | 2 | 변화 없음 | 0 |

FRR bgpd는 기동한 뒤 한동안(이번 측정에서는 기동 후 약 1분에는 R 비트가 섰고, 130초 뒤에는 서지 않았다) OPEN에 R 비트를 세운다. "나도 막 재시작했다"는 뜻이다.
재시작한 spine1은 R 비트를 세운 이웃의 End-of-RIB을 기다릴 대상에서 뺀다. 기다릴 이웃이 0이 되면 바로 "경로 정리 끝"을 zebra에 알리고, zebra가 지켜 두던 커널 경로를 지운다. 새 경로는 UPDATE가 온 1.1초 뒤에야 들어온다.
실제 패브릭에서는 리프와 스파인이 비슷한 때 함께 재부팅될 때(전원 복구, 일괄 업그레이드) 이 상황이 생긴다. 이 장의 Phase는 그래서 리프 기동 130초 뒤에 장애를 넣는다.

그 밖에 첫 실행에서는 랩을 새로 띄우지 않고 Phase를 이어 돌렸다. 앞 Phase의 bgpd 재시작 흔적이 남아 다음 Phase(B2)가 장애 전부터 경로가 없는 상태로 시작했다([capture/run1-output.txt](capture/run1-output.txt)의 B2: T0 전에도 응답 0). 원인은 끝까지 좁히지 못했다. Phase마다 랩을 새로 띄우는 것으로 피했다.

## 결론

스파인 bgpd를 `kill -9`로 죽였다가 watchfrr가 다시 띄우게 했다. GR이 없으면 7.43초 끊겼다. 재기동 5초와 세션·UPDATE 2초가 그대로 장애였다. 리프와 스파인 zebra 모두 TCP가 닫힌 순간 경로를 지웠기 때문이다. GR을 켜면 재기동 5초 동안은 양쪽이 stale 경로로 계속 포워딩했다. 하지만 `bgp graceful-restart`만 켰을 때는 새 OPEN의 F 비트가 0이었다. 리프는 RFC대로 stale을 지웠고, 세션이 다시 붙는 순간 1.22초가 끊겼다. `preserve-fw-state`까지 켜자 끊김이 0이 됐다. 다만 리프 bgpd가 막 기동한 상태(R 비트 SET)에서는 이것도 1.25초로 돌아갔다. GR은 켜기만 하면 되는 스위치가 아니다. F 비트, R 비트, End-of-RIB 대기가 모두 맞아야 0이 된다. 그 조건은 OPEN 패킷과 `EOR REQ` 로그에서만 보였다.

같은 GR이 진짜 장애는 오래 끌었다. 07과 똑같이 스파인을 얼리자 hold timer(8.2초)로 알아챘다. 그런데 RFC 8538 이후 hold timer 만료도 GR로 다뤄서, 리프는 죽은 스파인의 경로를 restart-time(30초) 더 ECMP에 남겼다. 끊김은 38.29초였다. 07에서 GR 없이 7.6초였던 장애다. 기본 restart-time 120초라면 2분이 넘는다. BFD(300ms × 3)를 더하면 freeze는 0.95초로 끝났다. BFD Down은 Hard Reset으로 나가서 stale을 남기지 않는다. 그런데 FRR 10.2.1에서는 그 BFD가 무중단 재시작을 2.15초짜리로 바꿨다. bgpd가 다시 붙는 순간 BFD 출발지 주소를 바꾸며 세션을 한 번 내렸고, 리프가 그 Down에 Hard Reset을 보냈다. `check-control-plane-failure`는 이 순간을 막지 못했다. 오히려 freeze 때의 BFD Down까지 무시해서 C의 함정으로 되돌아갔다. 이번에 잰 FRR에서는 "freeze 1초"와 "재시작 0초"를 한 설정으로 동시에 얻지 못했다. 고를 수 있는 조합은 GR + BFD(freeze 0.95초 / 재시작 2.15초)와 GR만(재시작 0초 / freeze 38초)이었다.

다음에 "컨트롤 플레인 재시작인데 트래픽이 끊겼다"를 만나면 이렇게 본다. 재시작한 장비의 새 OPEN에서 F 비트를, 이웃 OPEN에서 R 비트를, 재시작한 쪽 로그의 `EOR REQ`를, BFD가 세션이 붙은 직후 Down을 한 번 냈는지를 순서대로 본다. 반대로 "장비가 죽었는데 트래픽이 수십 초 블랙홀"이면 helper 쪽 `show bgp neighbor`의 `The remaining time of restart timer`부터 본다. 그 숫자가 블랙홀이 끝나는 시각이다.

### 한계

- 소형 랩이다(스파인 2, 리프 2, 경로 몇 개). 경로가 수십만 개면 End-of-RIB까지의 시간과 zebra가 stale을 정리하는 시간이 길어진다. 1.2초·2.2초 같은 숫자는 이 규모에서만 맞다.
- "재시작"은 `kill -9`다. 운영에서 하는 계획 재시작(업그레이드, `systemctl restart`)은 NOTIFICATION을 보내고 닫을 수 있어 helper 동작이 다를 수 있다. 재기동까지 5초는 watchfrr 설정(`--min-restart-interval 2`, 폴링 5초)에서 왔다.
- R 비트가 서는 기간(기동 후 약 1분에는 섰고 130초에는 서지 않음)은 두 점만 쟀다. 정확한 길이와 FRR 소스상의 이유는 확인하지 않았다.
- 첫 실행에서 본 Phase 사이 오염(앞 재시작의 흔적으로 B2가 시작부터 경로 없음)은 원인을 밝히지 못하고 Phase마다 랩을 새로 띄워 피했다.
- D4의 "복구하지 않았으면 약 38초"는 C와 같은 경로를 탔다는 로그에서 한 추정이다. 끝까지 재지 않았다.
- 각 Phase는 한 번씩만 돌렸다. 단, A·B1·D2·D3의 숫자는 여러 실행(run1·run2·최종)에서 ±0.05초 안이었다.
- ping은 커널 FIB만 탄다. 하드웨어 스위치처럼 FIB를 ASIC에 따로 내려 두는 장비에서는 zebra가 경로를 지우는 시점과 실제 포워딩이 멈추는 시점이 다를 수 있다.
- Wireshark 화면(img/)은 만들지 않았다. 위 패킷 흐름은 tcpdump -v와 frr.log를 옮긴 것이다.

## 파일

| 파일 | 내용 |
|---|---|
| `grlab.clab.yml`, `configs/` | 소형 랩. 노드별 frr.conf, daemons, watchfrr 재시작 간격만 고친 `docker-start` |
| `up.sh` / `down.sh` | 랩 띄우기(configs → state/<노드> 를 /etc/frr 로) / 지우기 |
| `run.sh` | Phase마다 랩 새로 → 설정 → 130초 대기 → 캡처 → 장애 → 결과 정리. 출력은 `capture/run-output.txt` |
| `restore.sh` | 중간에 멈췄을 때 run.sh·캡처를 끄고 스파인을 풀고 랩을 새로 띄움 |
| `sync.sh` | 윈도우 원본 → WSL 실행 사본, `sync.sh back`은 capture/를 되가져옴 |
| `capture/<Phase>-h1-eth1.pcap` | ping. 패킷당 128바이트, 끊김이 끝난 직후까지만(C·D1·D4는 T0+2초까지) |
| `capture/<Phase>-leaf{1,2}-ctl.pcap` | BGP + BFD 전체 |
| `capture/<Phase>-*-route.txt`, `<Phase>.T0` | 커널 경로 변화(`ip -ts monitor route`, WSL 시간대), 장애 시각(epoch) |
| `capture/run2-output.txt` | 리프 기동 직후(R 비트 SET)에 돌린 A~B3 (⑥) |
| `capture/run1-output.txt` | 랩을 Phase마다 새로 띄우기 전 첫 실행 (B2 오염, ⑥) |
