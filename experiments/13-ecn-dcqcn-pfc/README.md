# 13 — ECN · DCQCN · PFC: 신호, 규칙, 비상 브레이크 (진행 중)

> **상태 (2026-10-10):** A~F 1회 실행 완료, 결과는 [capture/](capture/). 본문(패킷 흐름·Wireshark 화면·결론)은 아직 안 썼다.
> 남은 일은 맨 아래 [다음에 할 것](#다음에-할-것).

실험 12 R5의 인캐스트(g1·g2·g4 → g3, leaf3:eth5를 300Mbit 포트로) 위에 세 가지를 하나씩 얹는다.

| | 무엇 | 이 랩에서 |
|---|---|---|
| ECN | 큐가 차면 패킷을 버리는 대신 IP 헤더에 CE 도장 | **진짜.** leaf3:eth5 의 RED 큐(`ecn`). RoCE 는 `--tclass=106`(DSCP 26 + ECT(0))로 보낸다. rxe 가 tclass 를 IP TOS 에 그대로 넣는 것을 캡처로 확인 |
| DCQCN | CE 를 본 받는 쪽(NP)이 CNP 를 보내고, 보내는 쪽(RP)이 속도를 깎았다 올린다 | **흉내.** [tools/dcqcn.py](tools/dcqcn.py). CNP 는 UDP 4792 패킷으로 패브릭을 실제로 건넌다. RP 는 gN 의 htb 클래스 속도를 바꾼다. 알고리즘 구조는 논문(Zhu et al. 2015) 그대로, 타이머만 µs → ms |
| PFC | 큐가 XOFF 를 넘으면 한 홉 앞 장비의 같은 클래스를 멈춘다 | **흉내.** [tools/pfc.py](tools/pfc.py). PAUSE 프레임 대신 앞 장비 tc 의 `plug` qdisc 를 block/release. RoCE 클래스(DSCP 26)만 따로 줄 세운다. leaf3:eth5 → 스파인 eth3 → 리프 업링크 → 서버 3홉까지 연쇄 |

흉내 쪽은 ms 단위로 반응해서, 문턱을 진짜 스위치보다 크게 잡았다(인캐스트 시작 때 큐가 1ms 에 약 340KB 씩 찬다): ECN 100~300KB, XOFF 1MB(XON 512KB), 병목 버퍼 4MB.

같은 시간에 RoCE 와 **같은 클래스**(DSCP 26)의 UDP 50Mbit 피해자 흐름 두 개를 흘린다.
- V1 h1 → h3: leaf3 까지 같은 길이지만 내려가는 포트(eth3)는 한가하다
- V2 h2 → h4: leaf3 를 지나지 않는다. leaf2 업링크만 g2 와 같이 쓴다

## 실행

```bash
experiments/12-roce/setup.sh                 # g1~g4 + rxe (모듈은 12 README 0단계)
ansible/run.sh prep-hosts.yml                # h서버 iperf3
experiments/13-ecn-dcqcn-pfc/run.sh          # A~F 전부 (약 3분). run.sh C E 처럼 일부만도 된다
experiments/13-ecn-dcqcn-pfc/restore.sh      # 13 이 바꾼 큐 원복 (g1~g4·rxe 는 남긴다)
```

## 1회차 결과 (2026-10-10, 커널 6.6.114.1)

| | 켠 것 | 합계 | 병목 드랍 | 병목 큐 중앙값 | PFC XOFF (leaf3) | 스파인 멈춤 | V1 손실 | V2 손실 |
|---|---|---|---|---|---|---|---|---|
| A | 꼬리 드랍 64KB | 15 Mbit | 51,061 | 0KB | — | — | 0% | 0% |
| B | ECN 만 | 293 | 0 | 1,517KB (41ms) | — | — | 0% | 0% |
| C | ECN + DCQCN | 229 | 0 | 182KB (5ms) | — | — | 0% | 0% |
| D | PFC 만 | 231 | 0 | 969KB (27ms) | 138 | 276 | 14.9% | 2.7% |
| E | ECN + DCQCN + PFC (ECN < XOFF) | 210 / 250 ⚠ | 8 / 2 | 85 / 121KB | 7 / 17 | 14 / 34 | 0.5 / 2.0% | 0.3 / 0.1% |
| F | 같은 구성, ECN 1.5~3MB > XOFF | 247 | 0 | 998KB (27ms) | 137 | 274 | 13.2% | 2.9% |

E 는 두 번 돌렸다(전체 실행 / E 만). 전체 출력은 [capture/run-output.txt](capture/run-output.txt), 시나리오별 원자료는 `capture/<A~F>/`
(bw-gN 처리량, np/rp.json DCQCN 통계, rp-timeline.csv 속도 변화, pfc.json·pfc-timeline.csv 멈춤, qdepth.jsonl 큐 깊이 20ms 간격, v1/v2.json 피해자, ping.txt).

첫 읽기:
- **B** — 도장 74,068개, 아무도 반응하지 않는다. 드랍이 없는 건 rxe 가 ACK 못 받은 패킷 128개(`RXE_MAX_UNACKED_PSNS`)에서 스스로 멈춰서다. 대신 큐가 1.5MB(41ms)로 계속 서 있다
- **C** — CNP 약 2,280개가 패브릭을 건너 왔고 송신자마다 약 480번 깎았다. 큐 중앙값 1.5MB → 182KB. 합계는 293 → 229 로 손해
- **D** — 병목 드랍 0. 멈춤이 스파인 → 리프 업링크 → 서버로 거꾸로 퍼졌다. 내려가는 포트가 한가한 V1, leaf3 를 지나지도 않는 V2 까지 손해(head-of-line blocking). V1 "손실" 에는 멈춘 사이 늦게 와서 측정 시간을 넘긴 몫이 섞여 있다
- **E vs F** — ECN 문턱이 XOFF 보다 낮으면 PFC 는 시작 순간에만 나선다(XOFF 7~17회). 뒤집으면 DCQCN 이 거의 안 움직이고(최저 속도 584~735Mbit) D 와 같아진다

## 알려진 문제

- **E 에서 송신자 하나가 결과 없이 멈춘다.** 3번 중 3번(g1, g1, g2). perftest 클라이언트가 헤더만 찍고 결과 줄 없이 timeout 으로 끝난다. QP 가 끊긴 건 아니다(`retry_exceeded_err` 0). C(DCQCN 만)·D(PFC 만)에서는 안 났다 → 흉내 DCQCN 과 흉내 PFC 가 같이 돌 때의 상호작용으로 보인다. 그래서 E 의 합계는 두 대 몫이다
- ECN 큐는 ECT 가 없는 패킷을 도장 대신 버린다. 그래서 ping 도 `-Q 0x02`(ECT)로 보낸다. 안 그러면 큐가 깊을 때의 ping 만 골라 사라져 지연이 낮게 보인다(첫 시도에서 손실 70%)
- `pfc.py` 의 메인 스레드가 `join()` 으로 기다리면 Python 3.13+ 에서 SIGTERM 을 못 받는다(첫 실행이 34분 멈춤). `stop.wait(0.2)` 루프로 고쳤고, run.sh 는 도구가 5초 안에 안 끝나면 강제로 끝낸다

## 다음에 할 것

1. E 멈춤 원인: 멈춘 송신자의 gN htb·plug 큐, rxe 카운터, DCQCN 속도를 시간대별로 같이 찍어 본다
2. 캡처 읽기: `C-leaf3-eth5.pcap` 의 CE(tos 0x6b), `C-leaf1-eth5-cnp.pcap` 의 CNP → Wireshark 화면(`_tools/ws-shot.ps1`)
3. DCQCN·PFC 타임라인 그림 (rp-timeline.csv, pfc-timeline.csv, qdepth.jsonl)
4. 본문·결론, [experiments/README.md](../README.md) 목록과 CHANGELOG
