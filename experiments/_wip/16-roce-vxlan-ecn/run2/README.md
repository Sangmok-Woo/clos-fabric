# 실험 18: RoCE over VXLAN — ECN 전달 누락

> [실험 목록](../README.md) · 진행: 2026-10-14 · 커널 6.6.114.1-microsoft-standard-WSL2

스파인이 VXLAN **바깥** 헤더에 찍은 혼잡 표시(CE)가 리프 VTEP에서 **안쪽** 헤더로 옮겨지지 않으면, 혼잡 제어 고리(스위치 표시 → 수신측 알림 → 송신측 감속)가 어떻게 끊기는지 잰다.

```
   g1(leaf1)  g2(leaf2)  g4(leaf4)            모두 VNI 10010, 10.10.10.0/24
        \        |        /                   gN = WSL 기본 netns 의 VRF vrN + veth xgN ↔ leafN:eth6(br10010)
         leaf1/2/4 업링크 eth1 ──── 장애2: 바깥 ECT 지우기(egress)
                 │  (spine2:eth3 은 내려서 경로를 spine1 로 고정)
               spine1 ── eth3 egress: 병목 300Mbit + RED(ecn)   ← 바깥 헤더에 CE
                 │
         leaf3 eth1 ingress ─────── 장애1: 바깥 CE → ECT(0) (디캡 직전)
         leaf3 (VTEP 디캡)
         leaf3 eth6 egress ──────── 대조군 병목 자리(디캡 이후, 안쪽 헤더에 CE)
                 │
                g3 (수신)
```

## 예측 (실험 전에 먼저 작성)

본 측정(Step 2~5) 결과를 보기 전에 적었다. 단, 스크립트 점검용 10초 시험 실행(트랙별 1회)은 먼저 돌렸고, 거기서 장애1 의 TCP 처리량이 277 → 184 Mbit 로 줄어드는 것을 이미 봤다 — 아래 Q2 예측은 핸드오프 가설을 그대로 옮긴 것이고 시험 실행을 보고 고치지 않았다. Step 1 의 답(Q1)은 측정 전에 `drivers/net/vxlan/vxlan_core.c` 를 먼저 읽어서 예측했다.

- **Q1 전달:** 리눅스 vxlan 은 캡슐화 때 `ip_tunnel_ecn_encap()` 로 안쪽 ECN 을 바깥에 복사하고(안쪽 CE 는 바깥 ECT(0)으로), 디캡 때 `INET_ECN_decapsulate()` 로 바깥 CE 를 안쪽에 옮긴다(RFC 6040). `tos` 옵션은 DSCP 만 바꾸고 ECN 처리에는 영향이 없을 것이다. → 그렇다면 장애1은 리눅스 VTEP 에서는 저절로 생기지 않는, **인위적 재현**이다.
- **rxe:** 실험 12에서 "rxe 는 ECN 을 찍지도 반응하지도 않는다"고 봤다. CE 를 받아도 CNP 를 만들지 않을 것이다 → 트랙 B(TCP+DCTCP)가 메인이 된다.
- **Q2 장애1 (핸드오프의 핵심 가설 그대로):** 스파인 표시 카운터는 정상인데 수신측 알림(ECE/CNP)이 0이 된다. 송신측이 감속하지 않아 큐가 버퍼 끝까지 차고 드랍 → 재전송 폭증 → **처리량 붕괴**.
- **Q2 장애2:** 스파인이 표시 대신 드랍한다. 손실 기반으로 떨어져 재전송이 늘고 처리량이 준다.
- **대조군:** 병목이 디캡 뒤에 있으면 표시가 안쪽 헤더에 바로 찍히므로 장애1 은 아무 영향이 없다.

## Step 0 점검 결과 (rxe DCQCN 지원 여부, 선택한 트랙)

전체 출력: [data/step0.txt](data/step0.txt) · 스크립트 [scripts/step0.sh](scripts/step0.sh)

| 항목 | 결과 |
|---|---|
| 토폴로지 | 스파인 2 + 리프 4 (eBGP 언더레이, VXLAN/EVPN). 베이스 VNI 10010 은 leaf1·leaf3 에만 있어서 실험 중에만 leaf2·leaf4 에도 만들었다 |
| rxe 위치 | rxe 는 netns 를 몰라서(실험 12) 서버를 컨테이너가 아니라 **WSL 기본 netns 의 VRF** 로 만들고, veth 반대쪽을 각 리프의 `br10010` 포트(eth6)로 꽂았다 → 리프 뒤 VNI 안 호스트 |
| 커널 / 모듈 | 6.6.114.1, `rdma_rxe`·`crc32_generic` 은 `/root/kbuild` 에서 빌드한 모듈 (실험 12 0단계), `tcp_dctcp` 있음 |
| MTU | 서버·VNI·브리지 9000, 언더레이 9500, RoCE active_mtu 4096. 8900B DF ping 통과. (베이스의 VNI MTU 1500 은 RoCE 4KB 프레임을 못 넘겨서 실험 중 9000 으로 올렸다) |
| rxe 계수기 | `ack_deferred completer_retry_err duplicate_request … sent_pkts` 16개. mlx5 의 `np_cnp_sent`·`rp_cnp_handled`·`np_ecn_marked_roce_packets` 같은 혼잡 제어 계수기가 **없다** |
| rxe 소스 | `cnp/ecn/congest` 를 쓰는 .c 파일 0개, `IB_OPCODE_CNP` 쓰는 곳 0개. BTH 의 FECN/BECN 은 `rxe_hdr.h` 에 함수만 있고 호출 0개 |
| **실측** | spine1:eth3 RED(ecn) 병목 + g1→g3 RoCE 10초(tclass 106 = DSCP 26 + ECT(0)). g3 앞(xg3)에 CE 패킷 **67,035개**가 도착. g3 → g1 은 **4,203개 전부 ACK(opcode 0x11), CNP(0x81) 0개**. g1 이 받은 CNP 0 |

**판단:** rxe 는 CE 를 받아도 CNP 를 만들지 않고, CNP 를 받는 코드도 없다. DCQCN 이 없으므로 "CE 를 못 받으면 감속을 못 한다"는 장애를 rxe 로는 만들 수 없다 → **트랙 B(TCP + DCTCP)를 메인으로 전환**했다.
트랙 A(rxe 그대로)는 "VXLAN 안쪽 RoCE 의 ECN 비트"와 "병목 손실 때 NAK/go-back-N" 관찰용으로 같이 돌렸고, 실험 13 의 흉내 DCQCN(`tools/dcqcn.py`, g3 앞에서 안쪽 CE 를 보고 UDP CNP 를 보내 송신측 htb 속도를 깎는다)을 얹은 **트랙 A'** 를 덧붙였다. A' 는 진짜 NIC 의 DCQCN 이 아니라 흉내라는 점을 결과 읽을 때 늘 같이 적는다.

## Step 1 — 신호 전달 (Q1)

전체 출력: [data/step1.txt](data/step1.txt) · CSV: [step1-encap.csv](data/step1-encap.csv), [step1-decap.csv](data/step1-decap.csv), [step1-traffic.csv](data/step1-traffic.csv)

**캡슐화 (안쪽 → 바깥).** g1 이 안쪽 TOS 를 바꿔 ping, 송신 리프 업링크 leaf1:eth1 에서 바깥 TOS 를 봤다 (조합마다 5개, 전부 같은 값).

| 안쪽으로 보낸 TOS | vxlan `tos 0`(기본) 바깥 | `tos inherit` 바깥 | `tos 0x68` 바깥 |
|---|---|---|---|
| 0x00 Not-ECT | 0x00 Not-ECT | 0x00 Not-ECT | 0x68 Not-ECT |
| 0x01 ECT(1) | 0x01 ECT(1) | 0x01 ECT(1) | 0x69 ECT(1) |
| 0x02 ECT(0) | 0x02 ECT(0) | 0x02 ECT(0) | 0x6a ECT(0) |
| 0x03 CE | **0x02 ECT(0)** | **0x02 ECT(0)** | **0x6a ECT(0)** |
| 0x6a DSCP26+ECT(0) | 0x02 ECT(0) | 0x6a | 0x6a |
| 0x6b DSCP26+CE | 0x02 ECT(0) | 0x6a | 0x6a |

ECN 두 비트는 옵션과 상관없이 늘 복사된다. 안쪽 CE 는 바깥에 CE 가 아니라 ECT(0)으로 나간다(RFC 6040 normal mode: 이미 찍힌 표시를 바깥 경로의 혼잡으로 다시 세지 않게). `tos` 옵션이 바꾸는 것은 **DSCP 뿐**이다. 기본값(0)에서는 RoCE 의 DSCP 26 이 바깥에서 사라진다 — 언더레이가 DSCP 로 RoCE 클래스를 나눈다면 그건 따로 문제가 된다(이 실험 범위 밖, 후속 과제).

**디캡 (바깥 → 안쪽).** spine1:eth3 egress 에서 pedit 으로 바깥 ECN 을 강제로 바꾸고, g3 앞(xg3)에서 안쪽 TOS 와 도착 수를 봤다. `tos 0` 과 `tos inherit` 결과가 같았다.

| 바깥 \ 안쪽 | Not-ECT | ECT(1) | ECT(0) | CE |
|---|---|---|---|---|
| Not-ECT | Not-ECT | ECT(1) | ECT(0) | CE |
| ECT(1) | Not-ECT | ECT(1) | **ECT(1)** | CE |
| ECT(0) | Not-ECT | ECT(1) | ECT(0) | CE |
| **CE** | **드랍 (0/5)** | **CE** | **CE** | CE |

바깥 CE 는 안쪽이 ECT 면 안쪽 CE 로 옮겨지고, 안쪽이 Not-ECT 면 표시를 전할 방법이 없어 **패킷을 버린다**(커널 로그 `vxlan: non-ECT from 10.255.1.1 with TOS=0x3`, 37줄). RFC 6040 의 디캡 표 그대로다.

**실제 병목에서.** spine1:eth3 에 RED(ecn) 를 걸고 TCP(DCTCP)·RoCE 를 5초씩 흘려, 스파인 표시 / leaf3 업링크 바깥 CE / g3 앞 안쪽 CE 를 셌다.

| vxlan tos | 트래픽 | 스파인 표시 | leaf3:eth1 바깥 CE | xg3 안쪽 CE | 송신 리프 업링크 바깥 ECT(0) |
|---|---|---|---|---|---|
| 0 | TCP | 42,491 | 42,491 | **42,491** | 2000/2000 (표본) |
| 0 | RoCE | 46,578 | 46,578 | **46,578** | 1999/1999 |
| inherit | TCP | 42,639 | 42,639 | 42,639 | 2000/2000 |
| inherit | RoCE | 46,801 | 46,801 | 46,801 | 2000/2000 |
| 0x68 | TCP | 42,337 | 42,337 | 42,337 | 2000/2000 |
| 0x68 | RoCE | 46,466 | 46,466 | 46,466 | 2000/2000 |

세 숫자가 한 개도 어긋나지 않는다. **리눅스 vxlan 은 기본값에서 CE 를 안쪽으로 옮긴다.** 따라서 아래 장애1 은 "바깥 CE 를 안쪽에 반영하지 않는 VTEP"(RFC 6040 이전 터널 규격들은 디캡 때 바깥 ECN 을 무시하는 동작을 허용했다)을 tc pedit 으로 **흉내 낸 인위적 재현**이다.
(Step 0·1 의 RoCE 병목 버퍼는 4MB, Step 2~5 는 1MB. 표시 전달만 보는 단계라 결과에 영향이 없다.)

<!-- 이하 Step 2~5 결과는 측정 후 채운다 -->
