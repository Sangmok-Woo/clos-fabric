# RUNBOOK — 따라 하는 절차

위에서부터 그대로 따라 하면 되는 문서다. **판단이 필요한 내용은 여기 두지 않는다** — 그건 [RULES.md](RULES.md).
따라 하다 틀린 곳이 나오면 그 자리에서 고치고, [CHANGELOG.md](../CHANGELOG.md)에 한 줄 남긴다.

명령은 전부 **Windows PowerShell**에서 친다.

| 절차 | 언제 |
|---|---|
| [R1. 랩 띄우기](#r1-랩-띄우기) | PC를 켜고 처음, WSL을 재시작한 뒤 |
| [R2. 원본 → 실행 사본 동기화](#r2-원본--실행-사본-동기화) | 윈도우 쪽 파일을 고친 뒤 |
| [R3. 재배포](#r3-재배포) | `configs/`·`clos.clab.yml`을 고친 뒤, 링크(veth)가 사라졌을 때 |
| [R4. 리프 1대 추가](#r4-리프-1대-추가) | 랙이 늘 때 |
| [R5. 고장 훈련 한 판](#r5-고장-훈련-한-판-5분) | 매일 |

---

## R1. 랩 띄우기

1. WSL이 저절로 꺼지지 않게 붙잡아 둔다 (꺼지면 랩의 veth가 전부 사라진다)
   ```powershell
   Start-Process -WindowStyle Hidden wsl -ArgumentList '-d','Ubuntu','-u','root','--','sleep','infinity'
   ```
2. dockerd를 띄운다 (WSL에 systemd가 없어서 저절로 안 뜬다)
   ```powershell
   wsl -d Ubuntu -u root -- service docker start
   ```
   안 뜨면 `wsl -d Ubuntu -u root -- bash -c "dockerd > /var/log/dockerd.log 2>&1 &"`
3. 처음이거나 윈도우 쪽 파일을 고쳤으면 → **R2**
4. 기동하고 점검한다
   ```powershell
   wsl -d Ubuntu -u root -- bash -lc "cd /root/labs/clos-fabric && ./scripts/deploy.sh up; sleep 10; ./scripts/check.sh"
   ```
   - 통과 기준: 세션 스파인 `4 / 4`·리프 `2 / 2`, ECMP `nexthop 2`, `h1 -> …` 전부 `OK`
   - `already exist`가 나오면 이미 떠 있는 것이다. 점검 결과만 보면 된다
   - 점검에서 세션이 0이거나 링크가 없다고 나오면 → **R3**

## R2. 원본 → 실행 사본 동기화

containerlab은 리눅스에서만 돌아서, 윈도우 원본을 WSL 안(`/root/labs/clos-fabric`)으로 복사해서 쓴다.

```powershell
wsl -d Ubuntu -u root -- bash -c "mkdir -p /root/labs/clos-fabric && cp -a /mnt/c/Users/$env:USERNAME/Desktop/Claude/clos-fabric/. /root/labs/clos-fabric/ && chmod +x /root/labs/clos-fabric/scripts/*.sh"
```

- `$env:USERNAME`은 PowerShell이 윈도우 사용자 이름으로 바꿔 넣는다. 사용자 폴더 이름이 다르면 직접 적는다
- **`cp -a`는 원본에서 지운 파일을 사본에서 지우지 않는다.** 원본에서 파일을 지우거나 이름을 바꿨으면 사본에서도 같은 파일을 지운다
- 사본을 통째로 지우고(`rm -rf`) 다시 복사해도 되지만, 그러면 고장 훈련 진도(`.day-state`)도 같이 지워진다
- 셸 스크립트가 `\r` 때문에 안 돌면: `sed -i 's/\r$//' scripts/*.sh` (`.gitattributes`가 LF로 고정하고 있어서 보통은 필요 없다)

## R3. 재배포

`configs/`는 **읽기 전용 마운트**라, 파일을 고치면 재배포해야 반영된다. 반대로 vtysh로 넣은 실행 중 설정은 재배포하면 전부 사라진다.

1. 고친 파일을 사본으로 → **R2**
2. 다시 세우고 점검한다 (1~2분)
   ```powershell
   wsl -d Ubuntu -u root -- bash -lc "cd /root/labs/clos-fabric && ./scripts/deploy.sh redeploy && sleep 12 && ./scripts/check.sh"
   ```
3. 재배포로 사라진 것 중 필요한 게 있으면 다시 넣는다

   | 사라지는 것 | 다시 넣는 법 |
   |---|---|
   | BFD | `./scripts/bfd-apply.sh on` |
   | VXLAN/EVPN | `./scripts/evpn-apply.sh` |
   | 걸려 있던 훈련 고장 | 같이 사라진다. `./scripts/day.sh 재배포`로 했다면 진도 상태도 정상으로 돌아간다 |

4. CHANGELOG에 **⚠ 재배포**를 붙여 무엇을 바꿨는지 적는다

> 확장 작업 3번(§7 정리 재배포)처럼 규칙이 바뀌는 대공사는 실제로 한 번 해본 뒤, 그 순서를 여기에 **R6**으로 적는다.

## R4. 리프 1대 추가

> ⚠ **아직 실제로 해본 적 없는 절차다.** 처음 따라 할 때 틀린 곳을 고칠 것.
> ⚠ 확장 작업 3번(재배포) **전후로 값이 다르다.** 아래 표에서 해당 열을 쓴다.

새 리프 번호를 **N**이라 한다. 번호는 재사용하지 않는다 — 철거한 번호는 건너뛴다.

| 값 | 지금 (재배포 전) | 재배포 후 ([RULES](RULES.md) §1~4) |
|---|---|---|
| 이름 | `leafN`, 서버 `hN` | 같음 |
| AS | `6501N` (leaf9까지만 된다) | `65100 + N` |
| 루프백 | `10.255.1.N/32` | 같음 |
| spine1 링크 | `spine1:ethN` ↔ `leafN:eth1`, `10.1.1.(2N-2)/31` ↔ `10.1.1.(2N-1)/31` | 같은 포트, **IP 없음** |
| spine2 링크 | `spine2:ethN` ↔ `leafN:eth2`, `10.1.2.(2N-2)/31` ↔ `10.1.2.(2N-1)/31` | 같은 포트, **IP 없음** |
| 서버망 | `172.16.1N.0/24` (게이트웨이 `.1`, 서버 `.10`) | `172.16.N.0/24` |
| 서버 포트 | `leafN:eth3` ↔ `hN:eth1` | `leafN:eth11` ↔ `hN:eth1` |

고칠 곳:

1. **`configs/leafN/frr.conf`** — 가장 가까운 리프 파일을 복사해서 위 표의 값으로 바꾼다: `hostname`, `lo` 주소, `eth1`·`eth2` 주소, 서버 포트 주소, `router bgp` AS, `bgp router-id`, 이웃 2개, `network` 2줄
   - 재배포 후: `eth1`·`eth2` 주소 줄은 없고, 이웃은 `neighbor eth1 interface peer-group FABRIC` / `neighbor eth2 interface peer-group FABRIC`
2. **`clos.clab.yml`** — `leafN` 노드(binds 3줄), `hN` 서버 노드(exec 3줄), 링크 3줄 (`spine1:ethN`–`leafN:eth1`, `spine2:ethN`–`leafN:eth2`, 서버 포트–`hN:eth1`)
3. **`configs/spine1/frr.conf`** — `interface ethN` + 주소, 이웃 2줄 (`peer-group FABRIC`, `description leafN`)
   - 재배포 후: `interface ethN` 주소 없이 `neighbor ethN interface peer-group FABRIC` + `neighbor ethN description leafN`
4. **`configs/spine2/frr.conf`** — 3과 같은 것
5. **스크립트** — `check.sh`의 리프·서버 목록과 기대 세션 수, `bfd-apply.sh`·`evpn-apply.sh`·`day.sh`(logsetup)의 장비 목록 (확장 작업 4번이 끝나면 이 단계는 없어진다)
6. **R2 → R3** (재배포) — 스파인 세션이 리프 수만큼 붙는지, `hN`까지 ping이 가는지 본다
7. CHANGELOG에 `⚠ 재배포 · leafN 추가`

리프를 많이 늘릴 거면 WSL 메모리 한도(`.wslconfig`, 지금 2GB)부터 올린다.

## R5. 고장 훈련 한 판 (5분)

1. 오늘 문제를 연다 — **고장은 이미 걸려 있다**
   ```powershell
   wsl -d Ubuntu -u root -- bash -lc "cd /root/labs/clos-fabric && ./scripts/day.sh"
   ```
2. 답을 먼저 **예측**하고, 화면에 뜬 확인 명령을 직접 쳐본다
3. 정답을 본다 — 해설과 자동 복구, 그리고 [LOG.md](LOG.md)에 오늘 줄이 붙는다
   ```powershell
   wsl -d Ubuntu -u root -- bash -lc "cd /root/labs/clos-fabric && ./scripts/day.sh 답"
   ```
4. LOG.md의 오늘 줄에 **원인·해결을 한 줄씩** 채운다

그 밖의 명령: `day.sh 목록`(전체 목록·진도), `day.sh 상태`, `day.sh 복구`(정답 안 보고 복구), `day.sh 12`(12일차로 건너뛰기)

> ⚠ 확장 작업 3번 재배포 뒤에는 `days.sh`에 박힌 링크 IP·AS·서버망이 틀린다. 그 전까지만 그대로 쓸 수 있다.
