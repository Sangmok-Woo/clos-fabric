# 실험 14 — ACL(stateless) vs 방화벽(stateful)

> [실험 목록](../../README.md) · 실험 노트 [NOTES.md](NOTES.md) · 실행 기록 [capture/run-output.txt](capture/run-output.txt)

같은 정책을 상태 없는 노드(ACL)와 상태를 기억하는 노드(FW)에 똑같이 주문하고, **상태 테이블(방명록) 유무**라는 구조 차이가 어디서 결과를 가르는지 잰다.

**가설:** 평상시엔 구별이 안 된다. ① 위조 ACK ② UDP 왕복 ③ 비대칭 라우팅 세 지점에서 갈린다. → **맞았다.** 여기에 ④ 테이블 고갈이 FW에만 걸린다.
(목록의 09 세션 테이블 고갈, 11 비대칭 라우팅이 이 장의 Phase 6·5로 들어왔다.)

## 구성

```
                 ┌─ acl ── serverA      nftables, ct 없음
   h1 ── leaf1 ──┤
                 └─ fw  ── serverB      nftables, ct 있음
         leaf1 ─────────── serverA, serverB   우회 링크 (Phase 5에서만 리턴 경로로 사용)
```

베이스 패브릭과 따로 뜨는 작은 랩(`fwacl`)이다. `clos.clab.yml`은 건드리지 않고, 패브릭과 동시에 떠 있어도 이름(`clab-fwacl-*`)이 안 겹친다.

**통제변인:** 전 노드 같은 이미지(`fwlab:1`, ubuntu 24.04 + nftables·conntrack·hping3·dnsmasq), 같은 커널 포워딩, 같은 규칙 골격. 다른 건 FW 쪽 `ct state` 두 줄뿐이다.
전 노드 관리망 없음(`network-mode: none`) — 관리망(clab)에 붙이면 도커가 컨테이너 안에 DNS용 NAT 규칙을 깔고, 그 순간 ACL 노드에도 conntrack이 켜진다(실측). 그러면 변수가 두 개가 된다.

## 주소계획

| 구간 | 서브넷 | 왼쪽 끝 | 오른쪽 끝 |
|---|---|---|---|
| h1 ↔ leaf1 | 10.14.1.0/24 | h1 .10 | leaf1 .1 |
| leaf1 ↔ acl | 10.14.2.0/24 | leaf1 .1 | acl .2 (eth1 = 내부) |
| leaf1 ↔ fw | 10.14.3.0/24 | leaf1 .1 | fw .2 (eth1 = 내부) |
| acl ↔ serverA | 10.14.10.0/24 | acl .1 (eth2 = 외부) | serverA .10 |
| fw ↔ serverB | 10.14.20.0/24 | fw .1 (eth2 = 외부) | serverB .10 |
| leaf1 ↔ serverB (우회) | 10.14.30.0/24 | leaf1 .1 | serverB .10 |
| leaf1 ↔ serverA (우회) | 10.14.40.0/24 | leaf1 .1 | serverA .10 |

leaf1은 `rp_filter=0` — 우회 링크로 들어오는 응답(출발지 10.14.20.x)을 역경로 검사로 버리지 않게.

## 실행

WSL root:

```bash
bash /mnt/c/Users/wsm02/Desktop/Claude/clos-fabric/experiments/_planned/14-acl-vs-firewall/sync.sh   # 윈도우 원본 → /root/labs 사본
cd /root/labs/clos-fabric/experiments/_planned/14-acl-vs-firewall
docker image inspect fwlab:1 >/dev/null 2>&1 || image/build.sh    # 최초 1회
containerlab deploy -t topology.yml          # 내리기: containerlab destroy -t topology.yml
./run.sh all                                 # Phase 0~6 → capture/run-output.txt   (한 단계만: ./run.sh 3)
```

노드 안에서 명령: `docker exec -it clab-fwacl-<노드> bash`. 이 디렉터리가 노드 안 `/lab`(읽기 전용)으로 보인다.

> Phase 6은 WSL 호스트의 `nf_conntrack_max`를 잠깐 40으로 낮춘다. 컨테이너(비 init netns) 안에서는 읽기 전용이라서다(실측). 한도는 netns마다 따로 적용되고, `run.sh`가 끝나면(중간에 멈춰도 `trap`으로) 262144로 되돌린다.

## 단계

| Phase | 주입 | 관찰 |
|---|---|---|
| 0 베이스라인 | 규칙 없음 | h1 ↔ serverA/B ping·curl 양방향 |
| 1 같은 정책 | `acl-v1.nft`(== ack) → `acl.nft`, `fw.nft` | 같은 매트릭스, acl:eth2 캡처, drop 카운터 |
| 2 구조 보기 | curl 한 번 | `nft list chain`, `conntrack -L`, `conntrack -E`로 한 연결의 생성→소멸 |
| 3 위조 ACK | 서버에서 `hping3 -A -p 80` → h1 | h1:eth1 캡처, hping3가 받은 회신 |
| 4 UDP 왕복 | h1 → 서버 DNS, ACL에 `udp sport 53` 추가, 출발포트 53 위조 UDP | 질의 성공 여부, h1 도착 수, FW의 UDP 엔트리 |
| 5 비대칭 라우팅 | 서버 → h1 리턴만 우회 링크로 | 매트릭스, FW 방명록, h1·fw 양쪽 캡처 |
| 6 conntrack 고갈 | 호스트 max 40, 서버마다 연결 60개 붙잡기 | 열린 수, 새 curl, 기존 장기 연결, dmesg |

## 결과

| 실험 | ACL (stateless) | FW (stateful) | 범인 |
|---|---|---|---|
| Phase 1 정상 왕복 | 1차(`== ack`) 실패 → 고친 뒤 OK | OK | SYN-ACK을 "응답"으로 묘사 못 한 규칙 |
| Phase 3 위조 ACK | **통과** 3/3, h1이 RST 회신 | 차단 0/3 | 깃발만 보는 판정 |
| Phase 4 UDP 응답 | 규칙 없으면 실패, `sport 53` 열면 위조 UDP도 통과 2/2 | OK, 위조 0 | UDP엔 깃발이 없다 |
| Phase 5 비대칭 라우팅 | 영향 없음 | **ping OK, curl 실패** (SYN_SENT 고착) | 방명록이 반쪽만 기록 |
| Phase 6 연결 폭주 (max 40) | 60/60, 새 curl OK | 39/60, 새 curl 실패, 기존 연결 OK | 방명록 용량 |

단계별 증상·추적·원인은 [NOTES.md](NOTES.md).

## 결론

평상시(Phase 1)에는 두 노드가 똑같이 보인다. 다만 그 "똑같음"을 만드는 수고가 다르다. FW는 `ct state established` 한 줄이면 되고, ACL은 응답의 모양을 사람이 묘사해야 한다. 스켈레톤 빈칸에 가장 먼저 떠오르는 `== ack`를 넣었더니 응답의 첫 패킷인 SYN-ACK이 걸러져 정상 접속부터 깨졌다. 고친 규칙(`ack|rst != 0`)은 시스코 `established`와 같은 뜻인데, 바로 그 규칙이 Phase 3에서 위조 ACK 3개를 전부 들여보냈다. h1은 RST로 답했고, 보낸 쪽은 h1이 살아 있다는 걸 알게 됐다. UDP(Phase 4)는 더 나쁘다. 깃발이 없으니 단서가 포트뿐이고, DNS 응답을 받으려고 연 `sport 53`은 "출발 53이면 누구든 어느 포트로든"이 되어 위조 UDP 2개가 h1에 닿았다. FW는 같은 질의를 방명록(UDP 의사 연결, 약 30초)으로 받고 위조는 하나도 들이지 않았다.

방명록은 약점도 만든다. 리턴 경로만 우회시키자(Phase 5) FW 쪽은 ping은 되는데 curl만 실패했다. FW가 SYN-ACK을 못 봐 연결이 `SYN_SENT [UNREPLIED]`에 멈췄고, 뒤따르는 h1의 ACK·GET 10개를 기록에 없는 패킷으로 버렸다. ACL은 기억하지 않으니 멀쩡했다. 다만 이 상태에선 서버의 선제 접속이 우회로로 검문소를 아예 건너뛰어 **둘 다** 통과했다. 비대칭 경로는 장애인 동시에 정책 구멍이다. 테이블 한도를 40으로 낮추자(Phase 6) FW는 정확히 40칸(붙잡은 39 + 장기 연결 1)에서 새 연결을 버렸다. 기존 연결과 ping은 멀쩡했고, 흔적은 dmesg의 `table full` 한 줄뿐이었다.

**한 문장:** 돌아오는 트래픽이 TCP 깃발로 구별되고 경로가 하나뿐인 내부 구간엔 ACL로 충분하고, UDP 응답을 받아야 하거나 위조 패킷이 들어올 수 있는 경계엔 stateful이 꼭 필요하다 — 단 stateful은 왕복 경로를 대칭으로 지키고 테이블 용량을 감시해야 한다.

다음에 "ping은 되는데 접속만 안 된다"를 만나면 경로 대칭(`conntrack -L`에 `UNREPLIED`가 쌓이는지)부터, "기존 연결은 되는데 새 연결만 안 된다"면 `conntrack -C` vs `nf_conntrack_max`와 dmesg부터 본다.

## 파일

| 파일 | 내용 |
|---|---|
| `topology.yml` | 랩 정의 |
| `nft/acl.nft`, `nft/fw.nft` | 양쪽 규칙. `acl-v1.nft`는 Phase 1의 틀린 1차 시도 |
| `run.sh` | `./run.sh all` 또는 `./run.sh <0~6>` — 단계별 주입·관찰·원복 |
| `sync.sh` | 윈도우 원본 → WSL 실행 사본 (CRLF 제거) |
| `tools/` | `hold.py`(연결 n개 붙잡기), `longlived.py`(장기 연결 하나) |
| `image/` | `fwlab:1` Dockerfile, 빌드 스크립트 |
| `NOTES.md` | 단계별 실험 노트 (시나리오/주입/증상/추적/원인/교훈) |
| `capture/run-output.txt` | 1회차 실행 기록 |
