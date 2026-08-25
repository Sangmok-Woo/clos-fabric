# clos-fabric — spine-leaf 데이터센터 패브릭 실습랩

스파인 2 + 리프 4 + 서버 6 = 컨테이너 12대로 만든 Clos 패브릭.
eBGP 언더레이 → ECMP → 장애/수렴 측정 → VXLAN/EVPN 오버레이까지 실제로 돌려본 랩이다.

- **원본(편집용)**: `C:\Users\sangmok\Desktop\Claude\clos-fabric`
- **실행용(WSL)**: `/root/labs/clos-fabric` — containerlab은 리눅스에서만 동작한다
- 문서: [docs/00-프로젝트-흐름.md](docs/00-프로젝트-흐름.md), [docs/10-확장규칙.md](docs/10-확장규칙.md), [docs/90-현업-예상질문.md](docs/90-현업-예상질문.md)

## 하루 5분 · 30일

이 랩을 매일 하나씩 고장 내고 고치는 30일 코스가 있다. → **[docs/40-하루5분-30일.md](docs/40-하루5분-30일.md)**

```bash
cd /root/labs/clos-fabric && ./scripts/day.sh      # 오늘 문제 (고장은 이미 걸려 있다)
./scripts/day.sh 답                                 # 정답 + 해설 + 자동 복구
```

## 빠른 시작

```bash
powershell -c "Start-Process -WindowStyle Hidden wsl -ArgumentList '-d','Ubuntu','-u','root','--','sleep','infinity'"
```

WSL이 조용히 종료되면 랩의 veth가 사라지므로 위 프로세스를 하나 띄워두고 시작한다. 그 다음:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u root -- bash -lc "rm -rf /root/labs/clos-fabric && cp -a /mnt/c/Users/sangmok/Desktop/Claude/clos-fabric /root/labs/ && chmod +x /root/labs/clos-fabric/scripts/*.sh && cd /root/labs/clos-fabric && ./scripts/deploy.sh up"
```

## 스크립트

| 명령 | 하는 일 |
|---|---|
| `./scripts/deploy.sh up\|down\|redeploy` | 랩 기동 / 철거 |
| `./scripts/check.sh` | BGP 세션·ECMP·서버 간 통신·BFD 상태 점검 |
| `./scripts/ecmp-hash.sh` | 해시 정책 0/1 에서 링크별 트래픽 분산 측정 |
| `./scripts/failover.sh link\|freeze` | 장애 주입 후 끊긴 시간 측정 |
| `./scripts/bfd-apply.sh on\|off` | BFD 적용/해제 |
| `./scripts/evpn-apply.sh` | VXLAN + BGP EVPN 구성 및 검증 |

## 측정된 값

| 항목 | 결과 |
|---|---|
| 링크 다운 복구 | 0.2초 |
| 스파인 무응답(BFD 없음) | 7.6초 |
| 스파인 무응답(BFD 300ms×3) | 0.8초 |
| ECMP 분산 (흐름 40개) | 해시 IP만: 41:1 → 해시 L4까지: 12:30 |
| 랙 넘는 L2 (VXLAN VNI 10010) | v1 ↔ v3 통신 성공, 원격 MAC을 leaf3 VTEP으로 학습 |
