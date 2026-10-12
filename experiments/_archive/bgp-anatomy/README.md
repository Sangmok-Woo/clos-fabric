# bgp-anatomy — BGP 해부 랩

데이터센터 패브릭(clos-fabric 본체)은 모든 라우터가 내 것이라 BGP의 "외교" 성격이 안 보인다.
여기서는 **작은 인터넷**을 따로 만들어, 세션이 태어나고(연결) 약속을 주고받고(능력·타이머)
경로에 도장이 쌓이고(AS_PATH) 외교관이 판단하고(정책) 그 판단이 사고로 번지고(하이재킹·유출)
걸러지는(필터·RPKI) 과정을 패킷으로 따라간다.

> 이 장은 clos-fabric 본체와 **배타적**으로 띄운다(둘 다 WSL, 메모리 공유). 베이스 패브릭을 건드리지 않는다.
> 폐기 실험이 아니라 본체와 토폴로지가 다른 별도 미니랩이라 `_archive/` 아래 독립 디렉터리로 둔다.

## 비유 지도

| 감각 | BGP의 실체 | 비유 |
|---|---|---|
| 연결 | TCP 179 세션 + 상태 머신(FSM) | 두 나라 사이의 전화선 |
| 약속 | OPEN 능력 협상 + KEEPALIVE/Hold timer | 수교 조약과 "정기적으로 안부" 약속 |
| 경로 | UPDATE의 프리픽스 + AS_PATH | 여권에 찍히는 출입국 도장 |
| 정책 | route-map, Local Pref, 필터 | 외교관의 판단: 누구 말을 믿고 누구에게 전할지 |

## 토폴로지: 미니 인터넷 (AS 6개)

```
                 AS400 (Tier-1 트랜짓)
                /         \          \
          AS200 ──peer── AS300      AS500 (피해자, 콘텐츠)
             \           /   \       203.0.113.0/24
              \         /     \
               AS100 (나)     AS666 (공격자)
          198.51.100.0/24      100.66.6.0/24
```

관계(현실 인터넷 흉내):
- AS200·AS300·AS500 은 AS400 의 **고객**, AS200↔AS300 은 **피어**
- AS100 은 AS200·AS300 둘 다의 고객(**듀얼홈**), AS666 은 AS300 의 고객(공격자)

**Local Pref 규칙 (Gao-Rexford):** 고객 경로 200 > 피어 150 > 프로바이더 100.
"돈 내는 쪽(고객) 경로를 우선"하는 현실 ISP 규칙. 이게 있어야 5-c 경로 유출이 현실처럼 번진다.
밸리 프리 필터: 피어·프로바이더에게는 **내 경로와 고객 경로만** 넘기고, 받은 경로엔 관계를 커뮤니티로 표시한다.

주소는 일부러 IPv4 numbered(unnumbered 아님) — 캡처에서 NEXT_HOP 이 바뀌는 게 눈에 보여야 하니까.
링크는 `10.a.b.0/30`(a<b 인 두 AS, 작은 쪽이 .1). 관찰용 호스트: h100·h500·h666.
RPKI 캐시 `rtr`(StayRTR)는 6단계에서만 쓴다.

| 노드 | AS | 프리픽스 | 역할 |
|---|---|---|---|
| r100 | 100 | 198.51.100.0/24 | 나 (듀얼홈 고객) |
| r200 | 200 | — | AS400 고객, AS300 과 피어 |
| r300 | 300 | — | AS400 고객, AS666 의 프로바이더 |
| r400 | 400 | — | Tier-1 트랜짓 |
| r500 | 500 | 203.0.113.0/24 | 피해자 (콘텐츠) |
| r666 | 666 | 100.66.6.0/24 | 공격자 |

## 관찰 도구 (랩의 현미경)

- 모든 링크 tcpdump → pcap (`capture/`). 패킷 앞 512B 만 저장.
- `./world.sh [프리픽스...]` — **세계 여론 지도**. 모든 라우터의 해당 프리픽스 best 경로(next-hop/LP/출처/RPKI/AS_PATH)를 한 표로. 하이재킹 때 세계가 어떻게 갈리는지 바로 보인다.
- `show bgp neighbor X` 세션 건강검진표, `show bgp ipv4 unicast P` 후보와 선택 이유, `soft-reconfiguration inbound` 로 입고 장부(received-routes).

## 실행

```bash
./up.sh                       # destroy→deploy→14세션 대기→world.sh
./run.sh                      # 1~6단계 순서대로 (각 단계는 끝에서 스스로 원복)
./world.sh 203.0.113.0/24     # 아무 때나 세계 지도
./down.sh
```

> veth 주의: WSL 배포판이 idle 로 꺼지면 dockerd 가 재시작되며 모든 랩의 veth 가 사라진다.
> 긴 실험은 배포판에 `sleep` 하나를 띄워 붙잡아 둔 채 돌린다(orchestrate 스크립트가 그렇게 한다).
> 링크가 안 생기면 `--reconfigure` 말고 `destroy→deploy`(up.sh 가 그렇게 한다).

## 1일차 — 연결 → 약속 → 경로

### 1단계. 연결: 세션이 태어나는 순간 (`stages/stage1-connection.sh`)
- **1-0 탄생:** r100↔r200 세션을 내렸다 올리며 FSM 을 실시간 관찰 — `Idle → Active/Connect → … → Established`. pcap `s1-birth` 에 TCP 3-way → OPEN×2 → KEEPALIVE 가 순서대로.
- **1-A 전화선 끊기:** TCP 179 를 양방향 DROP → 세션이 `Connect/Active` 에서 맴돈다(전화가 안 걸림).
- **1-B 잘못 건 전화:** 한쪽 `remote-as` 를 999 로 틀림 → OPEN 받자마자 **NOTIFICATION(OPEN Message Error / Bad Peer AS)** 보내고 끊음. pcap `s1-badas` 에 디코드됨.
- 질문(스스로): 양쪽이 동시에 TCP 를 열면? (Connection Collision — 라우터ID 큰 쪽이 이긴다)

### 2단계. 약속: 조약과 안부 인사 (`stages/stage2-capability.sh`)
- **2-0 능력 협상:** OPEN 안의 Capabilities — Multiprotocol(IPv4-unicast), 4-byte AS, Route Refresh, Graceful Restart, Hostname … `show bgp neighbor` 로 확인. pcap `s2-open`.
- **2-A Hold time 협상:** 한쪽이 5/15, 다른 쪽 10/30 → **작은 쪽(15초)** 으로 합의.
- **2-B 약속 위반 = 결별:** 이미 선 세션에서 r200→r100 의 KEEPALIVE(179 egress)만 끊음 → 약 30초(기본 hold) 뒤 **NOTIFICATION(Hold Timer Expired)** 로 결별. pcap `s2-holdexp`.
- **연결 고리:** EVPN 이 BGP 위에 올라타는 이유가 바로 이 **Multiprotocol 능력 협상**. clos-fabric 본체에서 EVPN 세션에 주소군을 더할 때 겪는 `NoNeg`(→ clear 필요)가 정확히 이 단계 얘기다.

### 3단계. 경로: 여권에 도장이 쌓인다 (`stages/stage3-path.sh`)
- **3-0 도장 쌓임:** 203.0.113.0/24(AS500 발)가 퍼진 모습. r400 은 `500`, r200/r300 은 `400 500`, r100 은 `200 400 500`. AS 하나 지날 때마다 AS_PATH 앞에 도장 하나.
- **3-A NEXT_HOP 변화:** eBGP 를 넘을 때 NEXT_HOP 이 광고하는 라우터 자신으로 바뀐다. pcap `s3-update`.
- **3-B Withdraw:** AS500 이 광고를 내리면 UPDATE 의 Withdrawn Routes 로 "이제 그 주소 안 살아요". 세계에서 사라진다. pcap `s3-withdraw`.
- **3-C 루프 방지:** 자기 AS 도장이 찍힌 경로는 입국 거부(AS_PATH loop). `allowas-in` 으로 뚫어도 best 는 여전히 자기 local.

## 2일차 — 정책 → 사고 → 방어

### 4단계. 정책: 외교관의 판단 (`stages/stage4-policy.sh`)
나가는 길은 내가 정하고, 들어오는 길은 부탁만 할 수 있다.
- **4-A 나가는 길:** 듀얼홈 r100 에서 r300 쪽 경로의 Local Pref 를 올림 → **내 트래픽만** r300 쪽으로. 남의 테이블은 그대로.
- **4-B 들어오는 길:** r300 쪽에 AS_PATH prepend(100 100 100) → **남들의** 테이블이 r200 쪽을 고르게 바뀜. `world.sh` 로 전/후 비교.
- **4-C community(no-export):** 경로가 피어/프로바이더로 더 안 퍼지고 받은 AS 에서 멈춘다.

### 5단계. 사고: 인터넷이 속는 방식 (`stages/stage5-incident.sh`)
> 규칙: 각 사고마다 배포 전에 **"어느 AS가 속을지" 예측**을 쓰고, `world.sh` 실측과 비교한다.

- **5-a 동일 프리픽스 하이재킹:** AS666 이 203.0.113.0/24 를 똑같이 광고 → 세계가 반으로 갈린다. 666 에 가까운 AS 는 가짜로, 500 에 가까운 AS 는 진짜로. h100 traceroute 로 데이터플레인까지.
- **5-b 더 구체적인 프리픽스:** AS666 이 /25 두 개를 광고 → best path 는 같은 프리픽스끼리만 비교하지만 **FIB 는 가장 긴 프리픽스**를 따른다. AS_PATH 가 길어도 거의 전 세계가 샌다.
- **5-c 경로 유출:** AS100 이 r200 에게 받은 경로를 r300 에게 그대로 재광고(아웃바운드 필터 없음) → r300 입장에선 **고객 경로(LP 200)** 라 프로바이더 경로보다 우선. 큰 트래픽이 조그만 AS100 으로 몰린다. **Gao-Rexford 가 사고를 키우는 구조.**
- **5-d 출처 위조:** AS666 이 AS_PATH 끝에 500 을 붙여 `666 500` 로 "500 한테 받았어요"인 척. 6단계에서 이게 왜 무서운지 드러난다.

### 6단계. 방어: 위조 소문 걸러내기 (`stages/stage6-defense.sh`)
- **6-A 기초 방어:** 고객 세션에 `prefix-list`/`max-prefix` → 5-a·5-c 류가 **입구에서** 막힌다(운영의 1차 방어선).
- **6-B RPKI ROV:** StayRTR 캐시(`172.20.20.240:8282`)에 라우터를 붙이고, 가짜 ROA(`rpki/roas.json`: 203.0.113.0/24 의 주인은 AS500/maxLength 24 …)로 Origin 검증. Invalid 는 LP 10 으로 깎아 안 뽑히게.
  - 5-a → **Invalid** (출처가 666)
  - 5-b → **Invalid** (maxLength 24 위반)
  - 5-d → **Valid 로 통과(!)** — 출처 AS 만 보니 500 이면 통과. RPKI 의 구멍.
- **마지막 교훈:** RPKI 는 여권의 **마지막 도장**만 본다. 중간 경로(5-d)는 못 막는다. 그 구멍을 메우려는 게 ASPA·BGPsec — 개념으로만.

## 파일

```
bgp-anatomy/
├── bgp.clab.yml       토폴로지 (AS 6개 + 호스트 3 + RTR)
├── configs/           라우터별 frr.conf, daemons(-M rpki), vtysh.conf
├── rpki/roas.json     StayRTR 용 가짜 ROA 목록
├── lib.sh             공통 함수 (c/nsx/dx/vt/cfg, cap_start/stop, wait_up, world)
├── world.sh world.py  세계 여론 지도
├── up.sh down.sh run.sh
├── stages/            stage1~6
├── capture/           pcap + stageN.txt 실행 기록
└── img/               (선택) Wireshark 화면
```

## 결과

아래는 WSL(containerlab 0.75 + FRR 10.2.1)에서 2026-10-12 에 돌린 실측이다. 실행 기록은 `capture/stage*.txt`,
패킷은 `capture/*.pcap`(저장용으로 앞부분만 남김). 배포 직후 14개 eBGP 세션이 2초 안에 Established.

**연결·약속(1~2단계).** 세션을 내렸다 올리면 FSM 이 Idle→Active→Established 로 흐르고, 그 사이 TCP 3-way →
OPEN×2 → KEEPALIVE 가 `s1-birth.pcap` 에 순서대로 찍힌다. TCP 179 를 양방향으로 막으면 세션은 Connect/Active 에서
맴돌고(전화가 안 걸림), remote-as 를 999 로 틀리면 OPEN 을 받자마자 NOTIFICATION(OPEN Message Error / Bad Peer
AS)이 `s1-badas.pcap` 에 잡힌다. OPEN 안의 Capabilities 로는 Multiprotocol·4-byte AS·Route Refresh·Graceful
Restart·Hostname 이 오갔다. Hold time 은 한쪽이 15, 다른 쪽이 30 이면 작은 15 로 합의됐다. 선 세션에서
KEEPALIVE 만 끊자 기본 hold(30초)가 만료되며 정확히 **30초** 뒤 NOTIFICATION(Hold Timer Expired)로 끊겼다
(`s2-holdexp.pcap`). 이 Multiprotocol 능력 협상이 바로 clos-fabric 본체에서 EVPN 세션에 주소군을 더할 때
겪는 `NoNeg` 함정과 같은 지점이다.

**경로(3단계).** 203.0.113.0/24(AS500 발)의 AS_PATH 는 r400 에서 `500`, r200/r300 에서 `400 500`,
r100 에서 `200 400 500` 으로, AS 를 하나 지날 때마다 앞에 도장이 하나씩 붙었다. r500 이 프리픽스를 내렸다 올리면
r400→r300 구간 UPDATE 에서 NEXT_HOP 이 광고하는 라우터(10.3.4.2)로 바뀌는 것과(`s3-update.pcap`), 내릴 때
Withdrawn Routes 로 세계에서 사라지는 것(`s3-withdraw.pcap`)을 확인했다. 자기 AS 도장이 찍힌 경로는 입국
거부(루프 차단)되어 r100 이 외부에서 받은 198.51.100.0/24 경로 수는 0 이었다.

**정책(4단계).** 듀얼홈 r100 에서 r300 쪽 인입 경로의 Local Pref 를 300 으로 올리자 내 트래픽만 r300 쪽으로
바뀌고 남의 테이블은 그대로였다. 반대로 r300 쪽 출력에 AS_PATH prepend(100 100 100)를 걸자 r300 은
`100 100 100 100` 을 보게 되고 r400·r666 은 r200 쪽(`200 100`)을 골랐다 — 들어오는 길은 부탁만 할 수 있다는 것.
no-export 를 붙인 경로는 r200 까지만 가고 r400 으로는 더 퍼지지 않았다(r400 의 r200 경유 경로 0).

**사고(5단계).** AS666 이 203.0.113.0/24 를 똑같이 광고하자 세계가 갈렸다: r300 은 고객 LP200 으로 `666`,
r200 은 피어로 `300 666`, r100 은 `200 300 666` 을 골랐고, r400·r500 만 진짜 `500` 을 지켰다. h100 의 핑은
공격자 r666 에 5/5 도달해 데이터플레인까지 샜다(r666 은 블랙홀로 버린다). /25 두 개를 광고한 경우, /24 best 는
여전히 500 이지만 FIB 는 더 긴 /25 를 따라 역시 r666 으로 5/5 샜다 — best 선택과 실제 전달이 다른 규칙으로 움직인다는 것.
경로 유출에서는 r100 이 r200 에게 받은 프로바이더 경로를 r300 에게 재광고하자, r300 이 그것을 고객 경로(LP200,
`100 200 400 500`)로 받아들여 큰 트래픽이 조그만 AS100 으로 몰렸다. 출처 위조는 `666 500` 으로 origin 이 AS500 처럼
보이게 만들었다.

**방어(6단계).** 고객 세션에 prefix-list(100.66.6.0/24 만 허용)를 걸자 203.0.113.0/24 하이재킹은 입구에서
0개로 차단됐다. StayRTR 캐시(172.20.20.240:8282)를 FRR rpki 모듈로 붙이면 3초 만에 연결되고 ROA 6개가 올라온다.
ROV(Invalid deny)를 고객 입구에 걸었을 때 5-a(출처 666)와 5-b(/25, maxLength 위반)는 Invalid 로 버려졌지만,
5-d(666 500, 출처가 500)는 **Valid 로 통과**했다. RPKI 는 여권의 마지막 도장(출처 AS)만 보기 때문이다. 이 구멍을
메우려는 것이 ASPA·BGPsec 다.

> 함정 기록 — ① r100 의 r300 쪽 이웃은 10.1.3.**2** 다(10.1.3.1 은 r100 자기 주소). ② FRR 이 설정 로드 중
> 일부 `neighbor … route-map in|out` 바인딩을 떨어뜨려 하이재킹이 전파·수신되지 않았다 → 배포 뒤 `harden`(lib.sh)이
> 그 줄들을 다시 박는다. ③ 소유하지 않은 프리픽스는 `network` 만으로 originate 안 된다(RIB 에 없음) → AD 10
> blackhole 스태틱으로 심고, 새 origination 은 soft-out 으로는 광고가 안 돼 하드 `clear` 가 필요하다(`hijack_add`).
> ④ `rpki cache` 는 FRR 10.2 에서 `rpki cache tcp <ip> <port>` 로, 연결까지 최대 ~15초. ⑤ 이 FRR 빌드는
> `no rpki` 로 rpki 를 끄면 bgpd 가 죽는 일이 있어, 6단계 원복은 ROV 강제만 풀고 캐시 연결은 남긴다(무해).
> ⑥ `--reconfigure` 는 veth 를 덜 정리해 링크가 안 생기므로 up.sh 는 destroy→deploy 로 간다. WSL 배포판이
> idle 로 꺼지면 모든 랩의 veth 가 사라지므로 긴 실험은 keepalive 를 붙잡고 돌린다.
