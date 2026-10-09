# ansible — 랩의 "상태 만들기"를 Ansible로

랩의 셸 스크립트 중 **장비를 어떤 상태로 만드는 것**을 Ansible playbook으로 옮겼다.
**보고, 재고, 흘리는 것**(캡처·트래픽·시간 측정)은 셸에 남겼다. 원래 셸 스크립트는 지우지 않았다. 나란히 놓고 비교하려고 남겨 둔 것이다.

## 실행

WSL에서 root로 돌린다. 반드시 `run.sh`를 거친다.

```bash
cd /mnt/c/Users/wsm02/Desktop/Claude/clos-fabric
./ansible/run.sh deploy.yml          # 랩 띄우기 + 수렴 확인
./ansible/run.sh check.yml           # 상태 점검
./ansible/run.sh bfd.yml --check     # 무엇이 바뀔지 미리 보기
./ansible/run.sh bfd.yml             # 적용
```

`run.sh`가 필요한 이유:
- **`/mnt/c`는 world-writable이라 Ansible이 `ansible.cfg`를 무시한다.** 그래서 `ANSIBLE_CONFIG`로 직접 지정한다.
- **Ansible은 `wsm0218`의 venv에 있고, containerlab·docker는 root로 돌린다.** 그래서 venv 경로를 직접 부른다.

윈도우 쪽 준비(WSL keepalive)는 Ansible 밖의 일이라 PowerShell에서 먼저 한다.
```powershell
Start-Process -WindowStyle Hidden wsl -ArgumentList '-d','Ubuntu','-u','root','--','sleep','infinity'
```

## 구조

```
ansible/
├── run.sh              실행기 (ANSIBLE_CONFIG + venv)
├── ansible.cfg
├── inventory.yml       장비 목록: fabric(spines, leaves) / servers / control(localhost)
├── group_vars/
│   ├── all.yml         랩 경로 (윈도우 원본, WSL 실행 사본)
│   ├── fabric.yml      BFD 값, EVPN VNI
│   ├── spines.yml      기대 세션 수(= 리프 수), 스파인의 EVPN 줄
│   └── leaves.yml      기대 세션 수(= 스파인 수), 리프의 EVPN 줄
├── host_vars/          장비마다 다른 값: AS, 루프백, 서버망, 링크(인터페이스·IP·상대)
│   └── spine1.yml ... leaf4.yml
└── *.yml               playbook
```

셸 스크립트에 흩어져 있던 값이 어디로 갔는지 보면 구조가 이해된다.

| 셸에 있던 것 | 예 | Ansible에서 사는 곳 |
|---|---|---|
| 장비 이름 목록 | `for n in spine1 spine2 leaf1 ...` | `inventory.yml` |
| 장비마다 다른 값 | `"leaf1 65011"`, `"leaf1 10.255.1.1"`, `awk '/^router bgp/'` | `host_vars/<장비>.yml` |
| 역할마다 같은 값 | 스파인 기대 세션 `4`, 리프 기대 세션 `2` | `group_vars/spines.yml`, `leaves.yml` (인벤토리에서 계산) |
| 랩 전체 값 | BFD `3 300 300`, VNI `10010` | `group_vars/fabric.yml` |

## 바꾼 것 (playbook)

| playbook | 원래 셸 | 셸에서 불편했던 점 | Ansible에서 |
|---|---|---|---|
| `deploy.yml` | `scripts/deploy.sh` + 손작업 | 한 줄짜리라, docker 기동·원본 복사·수렴 대기·점검을 손으로 했다. 배포 직후 점검하면 BGP가 아직 안 붙어 FAIL이 섞였다 | 준비부터 점검까지 한 파일. 이미 떠 있으면 건너뛰고, `check.yml`이 수렴할 때까지 기다린다 |
| `check.yml` | `scripts/check.sh` | 기대값(4, 2, 대상 IP)이 하드코딩. 틀려도 출력만 하고 종료 코드는 성공 | 기대값을 인벤토리에서 계산. 틀리면 실패로 끝나서 다른 playbook 끝에 붙일 수 있다 |
| `bfd.yml` | `scripts/bfd-apply.sh` | AS를 `awk`로 긁음. 매번 6대에 명령을 다시 넣음. on/off "명령" | AS는 host_vars에서. 이미 원하는 상태면 건너뜀(두 번째 실행 changed=0). `--check`로 미리 보기 |
| `evpn.yml` | `scripts/evpn-apply.sh` | `"leaf1 10.255.1.1"` 같은 짝을 하드코딩. `2>/dev/null \|\| true`로 에러 숨김. 매번 6대 BGP 세션을 끊음 | VTEP 여부와 주소는 host_vars에서. 없을 때만 만듦. 세션 재기동은 설정이 새로 들어간 장비만(handler) |
| `prep-hosts.yml` | `experiments/_tools/prep-hosts.sh` | 매번 apk를 다시 돌리고 httpd를 죽였다 살림 | 이미 돼 있으면 건너뜀. 서버에 python이 없어서 `raw` 모듈을 쓴다 |
| `monitoring.yml` | `monitoring/up.sh`, `down.sh` | 이미 떠 있어도 다 내리고 다시 띄움 | 떠 있으면 아무것도 안 함. Grafana·Prometheus가 실제로 응답할 때까지 확인 |
| `listen-range.yml` | `scripts/listen-range-test.sh` | 이웃 IP 목록 하드코딩. 중간에 멈추면 원복이 안 됨 | 이웃은 host_vars의 `links`에서. `block`/`always`로 실패해도 원복 |
| `unnumbered.yml` | `scripts/unnumbered-test.sh` | spine1·leaf1·eth1·IP·AS 전부 하드코딩 | 장비 이름 두 개만 받고 나머지는 `links`에서 찾음. 다른 링크로도 바로 실행 |

## 셸로 남긴 것

기준: Ansible은 **"장비가 이런 상태가 되게"**를 잘하고, 셸은 **"지금 이 동작을 하면서 지켜보고 재기"**를 잘한다.
Ansible은 작업 하나마다 접속·모듈 전송에 1초 안팎이 들어서, 밀리초를 재는 일에 끼면 숫자가 틀어진다.

| 스크립트 | 남긴 이유 |
|---|---|
| `scripts/capture.sh`, `stream.sh` | tcpdump를 백그라운드로 띄우거나 stdout으로 Wireshark에 흘린다. Ansible은 작업이 끝나야 출력을 돌려준다 |
| `scripts/traffic.sh` | 계속 도는 트래픽 생성기. "상태"가 아니라 "동작"이다 |
| `scripts/failover.sh`, `ecmp-hash.sh`, `monitoring/detect-time.sh`, `experiments/_tools/timeline.sh` | 시간·분산 측정. Ansible이 끼면 측정값이 Ansible 지연만큼 틀어진다 |
| `scripts/in.sh`, `experiments/_tools/lab.sh` | `nsenter` 한 줄을 감싼 편의 함수 |
| `experiments/_tools/detail.sh`, `ws-shot.ps1` | 윈도우(Git Bash·PowerShell)에서 도는 도구. 대상 장비가 없다 |
| `scripts/day.sh`, `days.sh` | 문제 내기·답 보기가 사람과 주고받는 흐름이고, 고장 주입은 대부분 한 줄이라 옮겨도 얻는 게 적다 |
| `experiments/NN-*/run.sh` (11개) | 주입 → 캡처 → 트래픽 → 원복이 초 단위로 맞물린다. 나중에 원복 부분만 playbook을 부르게 바꿀 수는 있다 |

## Ansible로 바꾸면서 배운 것

- **`command`/`raw` 모듈은 바뀌었는지 모른다.** 그래서 "지금 설정 읽기 → 비교 → 필요할 때만 적용"을 직접 짠다. 이게 멱등성의 실체다.
- **`--check`에서 `command`는 그냥 건너뛴다.** "계획" 단계(debug)를 따로 두고 `--check`일 때 changed로 집계되게 해서, 바뀔 장비가 보이게 했다.
- **원하는 상태는 장비가 실제로 보여 주는 모양으로 적어야 한다.** FRR은 `neighbor FABRIC attribute-unchanged next-hop`을 running-config에 보여 주지 않는다. 이 줄을 "있어야 할 줄"로 적었더니 매번 없다고 판단해 다시 넣었고, 그때마다 handler가 BGP 세션을 끊었다. 그래서 이 줄은 뺐다(EVPN next-hop은 원래 그대로 전달된다).
- **YAML 안 Jinja의 `'\n'`은 줄바꿈이 아닐 수 있다.** 접는 블록(`>-`) 안에서는 글자 그대로 `\n`이 됐다. 줄 나누기는 `.splitlines()`를 쓴다.
