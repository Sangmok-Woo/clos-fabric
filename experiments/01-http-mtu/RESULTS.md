# 결과 기록

날짜: 2026-09-26 (Claude 자동 실행 1회차)
장애 주입 지점: spine1:eth3 (mtu 9216 → 1500)
경로: v1(leaf1) → v3(leaf3), 언더레이 9216 / 오버레이 9000 / 해시정책 1

## Phase 0 베이스라인

| 항목 | 결과 |
|---|---|
| ping 기본 | 0% loss, rtt 0.15ms |
| ping -s 8000 -M do | 통과 |
| ping -s 1422 -M do | 통과 |
| ping -s 1423 -M do | 통과 |
| 1GB 소요 시간 / 처리량 | 3.03~3.18초 / 약 340MB/s (3회) |

## Phase 1 경로

캐시를 안 비웠을 때 (`via.sh`만):

| 시도 | 요청 방향 (leaf1→) | 데이터 방향 (leaf3→) |
|---|---|---|
| 1GB 단일 | spine1 | spine1 |
| 68MB × 8회 | 8회 모두 spine1 | 8회 모두 spine1 |
| 1GB 병렬 4개 | spine1 | spine1 (각 83~87MB/s, 합 약 340MB/s) |

매번 `ip route flush cache` 한 뒤 (`FLUSH=1`):

| 시도 | 요청 방향 | 데이터 방향 |
|---|---|---|
| 1 | spine2 | spine1 |
| 2 | spine2 | spine2 |
| 3 | spine1 | spine1 |
| 4 | spine2 | spine2 |
| 5 | spine2 | spine2 (중간에 spine1 592개) |
| 6 | spine2 | spine1 |
| 7 | spine1 | spine1 |
| 8 | spine1 | spine1 |
| 병렬 4개 (flush 1회) | 4개 모두 spine2 | 4개 모두 spine2 |

- 해시정책이 L4인데도 캐시가 살아 있는 동안에는 플로우별로 갈리지 않는다. 리눅스 vxlan 드라이버가 원격 VTEP별로 경로를 캐시하기 때문이다.
- 캐시를 비우면 요청 방향과 데이터 방향이 각자 다른 스파인을 고를 수 있다(1, 6번).

캡처 지점별 VXLAN 패킷 수:

| 지점 | p1-single | p1-parallel | p1-full | p2-fault |
|---|---|---|---|---|
| leaf1-eth1 | 184,000 | 674,718 | 8,867 | 97 |
| leaf1-eth2 | 0 | 0 | 0 | 0 |
| spine1-eth1 | 184,000 | 674,717 | 비슷 | 97 |
| spine1-eth3 | 184,002 | 674,717 | 비슷 | 97 |
| spine2-eth1 | 0 | 0 | 0 | 0 |
| spine2-eth3 | 0 | 0 | 0 | 0 |
| leaf3-eth1 | 184,002 | 674,717 | 비슷 | 258 |
| leaf3-eth2 | 0 | 0 | 0 | 0 |

(p1-single, p1-parallel, p2-fault는 cap.sh 수정 전에 센 값을 2로 나눴다. VXLAN 한 패킷이 tcpdump에서 두 줄로 찍혀서 원래 두 배로 세졌음)

Export Objects 복원: tshark `--export-objects http`로 spine1-eth1.pcap에서 video-small.mp4 복원 → 68,475,086B, md5 `2bebcb45…e094` **일치**.
영상 재생은 직접 확인할 것 (`pcap\p1-full\export-spine1-eth1\video-small.mp4`).
스파인 한 대 pcap만으로 복원: 캐시 때문에 한 플로우의 모든 패킷이 spine1에 있어서 spine1 pcap 하나로 온전히 복원됨. spine2 pcap은 비어 있음.

정상 상태에서도 68MB 전송 한 번에 TCP 재전송 137개가 잡혔다 (Wireshark 기준). 원인은 아직 안 봤다.

## Phase 2 장애 시도

캐시를 안 비웠을 때: 1GB 8회, 68MB 4회 **전부 0바이트, 20초 타임아웃**. 캐시가 spine1에 고정돼 있었다.

매번 캐시를 비웠을 때 (68MB, 10초 제한):

| 시도 | 데이터 방향 | 결과 |
|---|---|---|
| 1 | spine2 | 완료 0.21초 |
| 2 | spine1 | 0바이트 정지 |
| 3 | spine2 | 완료 0.23초 |
| 4 | spine2 | 완료 0.21초 |
| 5 | spine1 | 0바이트 정지 |
| 6 | spine1 | 0바이트 정지 |
| 7 | spine2 | 완료 0.21초 |
| 8 | spine1 | 0바이트 정지 |

멈춘 연결의 `ss -ti`: ESTAB, `bytes_received:198`, `rcvmss:536`. 응답 헤더(195B, 작은 패킷)만 받고 본문(8948B 세그먼트)은 하나도 못 받은 상태.

드랍 카운터: **spine1:eth3 RX dropped**와 **leaf3:eth1 TX dropped**가 같은 값(364)으로 같이 올랐다. veth는 한 번의 드랍을 양쪽 끝에 모두 기록한다.
spine2 쪽은 0.

## Phase 3 경계값

응답(leaf3→spine1)이 spine1을 타는 것을 `via.sh`로 확인하고 측정.

| 크기 | 결과 |
|---|---|
| 1422 | 통과 |
| 1423 | **통과** (예상은 실패) |
| 1424~1426 | 통과 |
| 1427 | 실패 |
| 1428, 1450, 1451 | 실패 |

실측 경계는 **1426/1427**. 예상(1422/1423)보다 4바이트 크다. 캡처로 확인한 내용:

- **응답 방향** (leaf3 → spine1:eth3 수신): 1423일 때 1515바이트 프레임(바깥 IP 1501)이 **그대로 도착**했다.
  veth는 수신 프레임을 `MTU + 14(이더넷) + 4(VLAN 태그 여유)`까지 받아준다. 1500+18 = 1518바이트 프레임 = 바깥 IP 1504 → 안쪽 ICMP 페이로드 1426이 한계.
- **요청 방향** (spine1:eth3 송신): 바깥 IP 1501은 **조각나서** 나갔다(1514바이트 첫 조각이 보이고 안쪽 ICMP가 1바이트 잘림).
  바깥 VXLAN 헤더에 DF가 없어서 스파인이 쪼개고 leaf3가 다시 합쳤다.
  즉 요청 방향은 MTU가 낮아도 안 죽는다. 경계를 결정한 건 응답 방향의 veth 수신 검사다.

산수: 1426 + 8(ICMP) + 20(안쪽 IP) + 14(안쪽 이더넷) + 8(VXLAN) + 8(UDP) + 20(바깥 IP) = 바깥 IP 1504, 프레임 1518.

## Phase 4 대조 매트릭스

| 항목 | 정상 | 장애 (spine1 경유 플로우) | 복구 후 |
|---|---|---|---|
| 연결 성립 | O | O (핸드셰이크·요청·응답 헤더까지 됨) | O |
| 전송 완료 | O | X (0바이트에서 정지) | O |
| 처리량 (1GB) | 약 340MB/s | 0 | 290~355MB/s |
| 경계 ping 1423 | 통과 | 통과 (veth +4 여유) | 통과 |
| 경계 ping 1427 | 통과 | 실패 | 통과 |
| 드랍 카운터 | 0 | spine1:eth3 RX = leaf3:eth1 TX 증가 | 416에서 멈춤 |

## 스크린샷 (직접)

1. VXLAN 계층 구조 — `pcap\p1-full\spine1-eth1.pcap`
2. Export Objects로 복원한 영상 — `pcap\p1-full\export-spine1-eth1\`
3. 스파인별 캡처 패킷 수 — `./cap.sh count p1-parallel`
4. 장애 시 멈춘 진행률 + 드랍 카운터 — README Phase 2 명령
5. 1426/1427 경계 ping
