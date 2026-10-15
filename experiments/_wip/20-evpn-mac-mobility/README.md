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
