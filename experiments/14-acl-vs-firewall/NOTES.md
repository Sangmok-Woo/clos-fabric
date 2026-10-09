# 실험 14 노트 (1회차 2026-10-10, 원본 출력은 [capture/run-output.txt](capture/run-output.txt))

> 형식: 시나리오명 / 주입 / 증상 / 추적 과정(틀린 가설 포함) / 원인·복구 / 한 줄 교훈

## Phase 0 — 베이스라인

규칙 없이 ping·curl 양방향 전부 OK. ACL 노드 conntrack 0개.
(FW 노드 4개는 직전 시운전의 TIME_WAIT 엔트리가 남은 것. 규칙을 지워도 이미 생긴 엔트리는 타임아웃까지 산다.)

## Phase 1 — 같은 정책 양쪽에 주문

- **주입:** 같은 정책 "내부→외부 허용, 외부 선제 접속 차단". ACL 1차는 스켈레톤 빈칸에 `== ack`.
- **증상:** ACL 쪽만 h1→serverA curl 실패(ping은 됨). FW 쪽은 정상.
- **추적:** acl:eth2 캡처에 SYN → SYN-ACK이 보이고, SYN-ACK이 재전송된다 → ACL 안쪽으로 못 넘어감. drop 카운터 9.
- **원인:** `flags & (fin|syn|rst|ack) == ack`는 "ACK **만**" 선 패킷이다. 응답의 첫 패킷 SYN-ACK은 syn|ack라 탈락.
- **복구:** `tcp flags & (ack|rst) != 0` (ACK나 RST가 서 있으면 통과 = 시스코 `established`) → 양쪽 모두 같은 결과.
- **교훈:** stateless는 "응답처럼 생긴 모양"을 사람이 정확히 묘사해야 한다. stateful은 `established` 한 단어로 끝.

## Phase 2 — 구조 들여다보기

- 규칙 목록은 둘 다 3줄. 차이는 `ct state` 유무뿐.
- curl 직후 `conntrack -L`: ACL **0개**, FW **1개**(TIME_WAIT, ASSURED).
- `conntrack -E`로 한 연결의 일생: NEW(SYN_SENT, UNREPLIED) → SYN_RECV → ESTABLISHED(타임아웃 432000s=5일) → FIN_WAIT → LAST_ACK → TIME_WAIT. ACL 노드는 이벤트 0.
- **교훈:** 방명록은 연결마다 메모리 한 칸 + 타이머. ESTABLISHED 기본 5일이라 정리 안 된 연결은 오래 남는다.

## Phase 3 — 위조 ACK

- **주입:** serverA/serverB에서 `hping3 -A -p 80 -c 3 h1`.
- **증상:** ACL 쪽 — 3개 모두 h1 도착, h1이 RST로 회신, hping3가 3/3 응답 받음. FW 쪽 — h1에 0개, 100% 손실, FW drop +3.
- **원인:** ACL은 깃발만 보고 "응답"으로 판단. FW는 방명록에 없는 ACK → (loose 모드에서) 외부발 `new`로 분류 → drop.
- **교훈:** ACL로는 ACK 스캔이 통과한다. 연결은 못 맺어도 "h1이 살아 있고 80이 어떤 상태인지"가 RST로 새어 나간다.

## Phase 4 — UDP 왕복

- ① 규칙 그대로: ACL 쪽 DNS 실패, FW 쪽 성공(UDP도 방명록에 의사 연결로 올라감, 타임아웃 ~30s).
- ② ACL에 `udp sport 53 accept` 추가 → 성공.
- ③ 그 구멍으로 serverA가 출발포트 53을 달고 h1:9999로 먼저 쏨 → **h1 도착 2/2**. FW 쪽은 0.
- **교훈:** UDP엔 깃발이 없어 ACL이 쓸 수 있는 단서는 포트뿐 → "출발 53이면 누구든 어느 포트로든"을 여는 것과 같다.

## Phase 5 — 비대칭 라우팅

- **주입:** 서버 → h1 리턴 경로만 우회 링크(leaf1 직결)로.
- **증상:** FW 쪽 — **ping은 되는데 curl만 실패**. ACL 쪽은 정상.
- **추적:**
  - h1 캡처: SYN → SYN-ACK 받음 → ACK·GET 보냄 → GET 재전송 반복, serverB는 SYN-ACK 재전송 → h1의 ACK가 서버에 안 닿는다.
  - fw:eth1 캡처: SYN·ACK·GET이 다 들어옴. 응답은 여기를 안 지남.
  - FW 방명록: `SYN_SENT [UNREPLIED]`에서 멈춤. drop 10 = h1의 ACK와 GET 재전송들.
  - 처음 가설 "ping도 막힐 것"은 틀렸다. ICMP 요청은 `new`라 통과하고 응답은 우회로로 오니 FW가 상관할 일이 없다.
- **원인:** FW가 SYN-ACK을 못 봐서 연결이 SYN_SENT에 머묾 → 다음 ACK는 기록과 안 맞는 invalid → drop.
- **덤 발견:** 이 상태에서 **server→h1 선제 접속이 양쪽 다 OK**. 서버의 SYN이 우회로로 바로 가서 검문소 자체를 안 거친다. 비대칭 경로는 장애이자 **정책 우회 구멍**.
- **교훈:** stateful은 왕복을 둘 다 봐야 한다. ACL은 기억을 안 하니 이 장애엔 안 걸리지만, 우회로가 생기면 정책은 둘 다 뚫린다.

## Phase 6 — conntrack 고갈

- **주입:** WSL 호스트 `nf_conntrack_max` 262144 → 40, h1이 각 서버로 연결 60개를 열어 붙잡음. 미리 연 장기 연결 1개.
- **증상:** FW 쪽 39/60 성공, 21 실패, 새 curl 실패. **기존 장기 연결은 계속 OK**. dmesg `nf_conntrack: table full, dropping packet`. ACL 쪽 60/60, curl OK.
- **원인:** 39 + 장기 연결 1 = 정확히 40. 꽉 찬 방명록에 새 손님 자리가 없다. ASSURED 엔트리라 early drop으로도 못 비운다.
- **교훈:** 핑·기존 세션은 멀쩡하고 새 연결만 실패하는 유령 장애. 볼 곳은 `conntrack -C` vs `nf_conntrack_max`와 dmesg.

## 블라인드 회차

(아직)

## 결론 한 문장

"되돌아오는 트래픽이 TCP 깃발로 충분히 구별되고 경로가 하나뿐인 곳(예: 내부망 구간 필터, 라우터 인터페이스)엔 ACL로 충분하고, UDP 응답을 받아야 하거나 위조 패킷이 들어올 수 있는 경계(인터넷 엣지)엔 stateful이 꼭 필요하다 — 단 stateful은 왕복 경로를 대칭으로 지키고 테이블 용량을 감시해야 한다."
