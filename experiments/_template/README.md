# 실험 NN — 제목

> [실험 목록](../README.md) · 실행 기록 [capture/run-output.txt](capture/run-output.txt)

무엇을 보려는 실험인지 두세 줄로.

## 장애 구성

```
  (장애 지점과 캡처 지점을 그린 작은 그림)
```

| 항목 | 값 |
|---|---|
| 주입 지점 | 예: spine1:eth3 |
| 바꾸는 값 | 예: MTU 9500 → 1500 |
| 관찰 구간 | 예: h1(leaf1) → h3(leaf3) |
| 캡처 지점 | 장애 앞과 뒤 |

## 실행

```bash
cd /root/labs/clos-fabric/experiments
_tools/prep-hosts.sh       # 랩을 새로 띄웠을 때 한 번
NN-이름/run.sh
```

## 숫자

## 패킷 흐름 ① ...

![화면 설명](img/01-....png)

## 결론

무엇을 넣었고 겉으로 어떻게 보였는지, 숫자 한두 개와 왜 그랬는지를 두세 문단의 글로 쓴다.
마지막에 다음에 같은 증상을 만나면 어디부터 볼지 한두 문장.

## 파일

| 파일 | 내용 |
|---|---|
| `run.sh` | 주입 → 캡처 → 트래픽 → 원복 |
| `restore.sh` | 중간에 멈췄을 때 원복 |
| `capture/` | 원본 pcap(패킷당 앞부분만), 실행 기록 |
| `img/` | Wireshark 화면 |
