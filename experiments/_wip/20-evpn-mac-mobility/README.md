# 실험 20 — EVPN MAC 이동과 중복 MAC 감지

> [실험 목록](../../README.md) · 앞 장 [03 L2 루프](../../_completed/03-broadcast-storm/README.md), [08 EVPN-VXLAN 패킷 추적](../08-packet-life-evpn/README.md) · 실행 기록 [capture/run-output.txt](capture/run-output.txt)

VM 이 다른 랙으로 옮겨 가면 EVPN 은 새 리프가 같은 MAC 을 **MAC Mobility 순번을 하나 올려** 광고하는 것으로 이사를 알린다. 03장은 브리지 고리 때문에 남의 MAC 을 광고해 순번이 폭주하는 것을 봤다.
이 장은 정상적인 이사(GARP 있음 / 없음)에서 트래픽이 얼마나 끊기는지, 그리고 같은 MAC 이 두 랙에 동시에 있을 때(복제된 VM) FRR 의 중복 감지가 언제 어떻게 막는지를 잰다.

## 장애 구성

```
  vmA ── leaf1:eth7 ─┐                       ┌─ leaf3 ── g3 (10ms 마다 VM 에 ping)
                     ├── VNI 10010 (EVPN) ───┤
  vmB ── leaf2:eth7 ─┘                       └─ (주소록: show evpn mac vni 10010 mac …)
  vmA·vmB 는 같은 MAC 02:21:00:00:00:01, 같은 IP 10.10.10.121 — 한쪽 링크를 내리고 다른 쪽을 올리는 것이 '이사'
```

| 시나리오 | 내용 |
|---|---|
| A | 기준: VM 은 leaf1 |
| B | 이사 leaf1 → leaf2, 도착하자마자 GARP 3개 |
| C | 조용한 이사 leaf2 → leaf1, GARP 없음 |
| C2 | (C 를 보고 덧붙임) 진짜 조용한 이사 leaf1 → leaf2: VM 의 IPv6 를 꺼서 링크가 올라와도 DAD/MLD 를 안 보내게 |
| D | 중복 MAC: vmA·vmB 둘 다 켜고 각자 0.5초마다 GARP, 60초 — FRR 기본 감지값 |
| F | D 와 같고 `dup-addr-detection freeze 30` |

## 실행

```bash
experiments/_wip/16-roce-vxlan-ecn/run2/scripts/setup.sh    # VNI 10010 을 leaf2 에도, g3 = vr3
experiments/_wip/20-evpn-mac-mobility/run.sh                # A~F (약 5분), 끝에 restore.sh
```

## 예측 (실행 전에 적음)

- B: GARP 가 leaf2 에 MAC 을 바로 심고, EVPN Type-2 가 순번 1 로 퍼진다. eBGP 라 광고 지연이 거의 없어 끊김은 수백 ms 이하.
- C: leaf1 은 링크가 내려가며 MAC 을 지우고 철회하지만 leaf2 는 VM 이 말을 할 때까지 모른다. leaf3 는 주소를 잃고 BUM 으로 흘리고(유니캐스트 모름), 그 플러딩이 leaf2 → vmB 에 닿아 VM 이 답하면 그제야 배운다. 끊김은 B 보다 길다 — 1초 안팎.
- D: FRR 기본값(180초 안에 5번 이동이면 중복)으로 0.5초마다 오가면 3초 안에 감지된다. 감지돼도 freeze 가 꺼져 있으면 광고는 계속 바뀌고 ping 은 절반쯤 맞는다.
- F: freeze 가 켜지면 감지 순간 MAC 이 한 자리에 묶여 순번이 더 오르지 않고, 30초 뒤 풀려 다시 오간다.

## 숫자

원자료 [capture/](capture/) — `run-output-main.txt`(A~F), `run-output.txt`(C2 포함 누적), 시나리오별 `*-ping.txt`(g3 → VM 10ms ping, `-D -O`), D·F 의 1초 주소록 기록 `*-timeline.txt`. FRR 기본값: `Duplicate address detection: Enable, max-moves 5, time 180`, freeze 꺼짐.

| | 무엇 | leaf3 주소록이 새 자리를 가리킨 시각 | ping 끊김 (10ms 간격) | MAC Mobility 순번 |
|---|---|---|---|---|
| A | 기준 (leaf1) | — | 0 / 311 | 0 |
| B | 이사 + GARP 3개 | T0 + **0.48초** | 7개, 최장 **70ms** | 0 → 1 (leaf2) |
| C | 조용한 이사 (GARP 없음) | T0 + **0.32초** | 6개, 최장 60ms | 1 → 2 (leaf1) |
| C2 | IPv6 까지 끈 조용한 이사 | T0 + 0.33초 | 6개, 최장 60ms | → leaf2 |

| 60초, 두 VM 이 0.5초마다 번갈아 GARP | 중복 감지 | 스파인1 이 받은 EVPN 메시지 | MAC 순번 (60초 뒤) | ping 손실 |
|---|---|---|---|---|
| D 기본 (freeze 꺼짐) | **+1초** (leaf1·leaf2 둘 다 "Duplicate") | **2,307** | 2 → **243** | 2 / 6,546 |
| F `freeze 30` | +2초 | **251** (−89%) | 243 → 252 | 2 / 6,539 |

## 추적 과정

1. **C 에서 예측이 틀렸다.** GARP 없는 이사가 1초 안팎 걸릴 거라 봤는데 0.32초로 B 보다 빨랐다. 처음엔 링크가 올라올 때 리눅스가 보내는 IPv6 DAD·MLD 가 "VM 이 말한 것"이 됐다고 보고, VM 의 IPv6 를 끄고 다시 쟀다(C2).
2. **C2 도 0.33초.** leaf2:eth7(VM 쪽) 캡처를 보면 VM 의 첫 프레임은 GARP 도 ND 도 아니라 **g3 의 ping 에 답하려고 보낸 ARP 요청**이다: leaf1 이 링크를 잃으며 MAC 을 철회 → leaf3 는 VM MAC 을 모르니 g3 의 ping 을 BUM 으로 모든 VTEP 에 흘림 → leaf2 를 거쳐 vmB 에 닿음 → vmB 가 g3 를 ARP 로 찾고 응답 → leaf2 가 그 출발 MAC 을 배워 Type-2(순번 +1) 광고. 즉 **누가 말을 걸고 있으면** 조용한 이사도 플러딩으로 바로 찾아진다. 아무도 말을 걸지 않는 VM 이었다면 다음에 VM 이 무언가 보낼 때까지 주소록이 옛 자리를 가리켰을 것이다(이번엔 재지 않았다).
3. 측정 중 사고 두 가지: ① 첫 실행 도중 병렬로 돌던 다른 작업(21장 에이전트)이 공유 스크래치 폴더의 복구 스크립트를 잘못 실행해 패브릭을 재배포했다 → VM 자리 veth 가 사라져 B 이후가 전부 무효, 다시 돌렸다. ② 중복 감지 시각 출력이 두 번 찍히는 버그(`+1초1`)를 고쳤다.

## 결론

EVPN 의 VM 이사는 빠르다. GARP 가 있으면 leaf3 주소록이 0.48초 만에 새 리프를 가리켰고, 10ms ping 은 70ms(7개)만 끊겼다. MAC Mobility 순번은 이사마다 정확히 하나씩 올랐다(0 → 1 → 2). 예상과 달리 GARP 가 없어도 빨랐는데, VM 이 먼저 말해서가 아니라 옛 리프가 MAC 을 철회하자 원격 리프가 그 MAC 앞 트래픽을 BUM 으로 흘렸고, 그게 새 자리의 VM 에 닿아 VM 의 응답(ARP)으로 새 리프가 배웠기 때문이다. 조용한 이사의 복구 속도는 "그 VM 에 계속 말을 거는 쪽이 있는가"에 달려 있다.
같은 MAC 이 두 랙에 동시에 있으면(복제된 VM, 잘못 꽂은 이중화 NIC), 0.5초마다 오가는 이동을 FRR 이 1초 만에 중복으로 잡았다(180초에 5번 기준). 하지만 기본값은 감지만 하고 막지 않는다 — 60초 동안 순번은 243 까지 올랐고 스파인은 EVPN 메시지 2,307개를 중계했다. 03장의 MAC Mobility 폭주가 고리에서 나왔다면 여기서는 복제 MAC 하나로 같은 일이 난다. `freeze 30` 을 켜면 감지 순간 그 MAC 을 한 자리에 묶어 30초 동안 광고를 멈추고, 메시지가 251개(−89%)로 줄었다. 이번에는 두 VM 이 같은 IP 로 둘 다 ping 에 답해서 손실이 거의 없었지만, 실제 복제 VM 이라면 30초 동안 트래픽이 한쪽에만 가는 것이 freeze 의 대가다.
VM 이사 뒤 끊김이 길면 원격 리프의 `show evpn mac vni … mac …` 에서 원격 VTEP 과 순번이 바뀌었는지부터 보고, 순번이 계속 오르면 같은 MAC 이 두 군데 있는지(`show evpn mac vni … duplicate`)를 본다.

## 한계

- VM 은 netns 두 개와 링크 up/down 으로 흉내 냈다. 실제 VM 이사(메모리 복사 뒤 전환, 하이퍼바이저의 RARP/GARP)와 시간 구성이 다르다
- 관측자가 10ms 마다 ping 을 보내 조용한 이사를 일부러 깨운다. 아무도 말을 걸지 않는 VM 의 이사는 재지 않았다
- 복제 MAC 의 두 VM 이 같은 IP 로 둘 다 답해서 D·F 의 ping 손실은 피해를 보여 주지 못한다. 서로 다른 서비스를 하는 복제 VM 이었다면 응답이 섞였을 것이다
- FRR 10.2.1, eBGP 기본 광고 간격. 다른 구현의 중복 감지·freeze 동작은 다를 수 있다

## 파일

| 파일 | 내용 |
|---|---|
| `run.sh` | A B C C2 D F (부분 실행 가능), 끝에 restore.sh |
| `garp.py`, `gap.py`, `macjson.py` | GARP 보내기, ping 끊김 계산, FRR MAC json 한 줄 요약 |
| `restore.sh` | VM netns·leaf1/2 eth7 삭제, freeze 해제, 중복 상태 지우기 |
| `capture/` | 실행 기록, ping 기록, 주소록 기록, C2 의 leaf2:eth7 캡처 |
