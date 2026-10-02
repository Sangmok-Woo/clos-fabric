# (보관) 옛 실험 01 — HTTP 대용량 전송 관찰 + MTU 장애 비교

> 2026-10-02 보관함으로 옮겼다. 지금의 실험 01은 [숨은 MTU 결함 + 스파인 장애](../../01-hidden-mtu-meets-spine-failure/README.md)다. 스크립트의 윈도우 사본 경로는 옛 위치를 가정한다.

> [실험 목록](../README.md) · 결과는 [RESULTS.md](RESULTS.md) · 사례 정리는 [CASE.md](CASE.md)

EVPN-VXLAN 패브릭 위로 HTTP 전송을 흘려서 세 가지를 본다.
패킷 생김새(VXLAN 캡슐화), 경로(ECMP로 어느 스파인을 타는지), MTU 장애가 있을 때와 없을 때의 차이.

이 디렉터리는 환경과 관찰 명령만 준비한다. 해석은 직접 한다.

## 핸드오프 문서와 다른 점

| 핸드오프 | 실제 | 이유 |
|---|---|---|
| 리프1 → 리프6 (없으면 리프4) | **리프1 → 리프3** (v1 → v3) | VNI 10010 호스트가 leaf1(v1)·leaf3(v3)에만 있다. leaf4에 붙이려면 EVPN 설정을 바꿔야 해서 제약 위반 |
| 언더레이 9216 가정 | 원래 **9500** (containerlab 기본값) | setup.sh가 9216으로 맞춘다 |
| (언급 없음) | 오버레이 원래 **1500** | `ping -s 8000`이 되려면 필요. br/vni/eth4/호스트 NIC를 9000으로 |
| (언급 없음) | ECMP 해시정책 원래 **0 (IP만)** | 0이면 leaf1↔leaf3 VXLAN이 전부 한 스파인으로 간다. 1(L4)로 바꾼다 |
| python3 http.server | busybox httpd | 알파인 호스트. curl·ss·iputils-ping도 apk로 설치 |

BGP·EVPN·주소는 건드리지 않는다. 바꾼 값은 전부 `state/`에 적어두고 `teardown.sh`가 되돌린다.

## 파일

| 파일 | 하는 일 |
|---|---|
| `setup.sh` | MTU 통일, 해시정책, 도구 설치, 테스트 파일, httpd 기동 |
| `ifmap.sh` | 캡처 지점 인터페이스 맵 출력 |
| `cap.sh` | 8개 지점 동시 캡처. `start hdr\|full <태그>` / `stop` / `count <태그>` |
| `via.sh` | 명령 하나를 실행하는 동안 리프 업링크 카운터 증가량 → 어느 스파인을 탔는지 |
| `fault.sh` | `inject [spine1\|spine2]` / `restore` / `status` (MTU + 드랍 카운터) |
| `teardown.sh` | 전부 원복하고 검증. `PURGE=1`이면 테스트 파일도 삭제 |
| `make-video.cmd` | (윈도우) ffmpeg로 재생 가능한 테스트 영상 `files/video-small.mp4` 생성 |
| `RESULTS.md` | 결과 기록용 표 |
| `CASE.md` | 사례 문서 뼈대 |

테스트 파일 (서버 v3의 `/srv`):

| 파일 | 크기 | md5 |
|---|---|---|
| video-large.bin | 1GB (urandom) | 3376dfd8679774519f70152e94824e94 |
| video-small.mp4 | 68MB (1280x720, 60초, H.264) | 2bebcb452e0e0a8db625a048ce66e094 |

## 시작

```bash
# 윈도우 PowerShell: 배포판 붙잡아두기 (안 하면 veth가 사라진다)
Start-Process -WindowStyle Hidden wsl -ArgumentList '-d','Ubuntu','-u','root','--','sleep','infinity'
wsl -d Ubuntu -u root
```

```bash
cd /root/labs/clos-fabric
./scripts/deploy.sh up && sleep 20 && ./scripts/evpn-apply.sh   # 랩이 없을 때만
cd experiments/01-http-mtu
./setup.sh
./ifmap.sh
```

아래 명령은 전부 `/root/labs/clos-fabric/experiments/01-http-mtu`에서 실행한다.
`V1`을 줄여 쓰려면 `V1="docker exec clab-clos-v1"`.

캡처 지점 맵 (`./ifmap.sh` 출력):

| 지점 | 상대편 | 주소 |
|---|---|---|
| leaf1:eth1 | spine1:eth1 | 10.1.1.1/31 |
| leaf1:eth2 | spine2:eth1 | 10.1.2.1/31 |
| spine1:eth1 | leaf1:eth1 | 10.1.1.0/31 |
| spine1:eth3 | leaf3:eth1 | 10.1.1.4/31 |
| spine2:eth1 | leaf1:eth2 | 10.1.2.0/31 |
| spine2:eth3 | leaf3:eth2 | 10.1.2.4/31 |
| leaf3:eth1 | spine1:eth3 | 10.1.1.5/31 |
| leaf3:eth2 | spine2:eth3 | 10.1.2.5/31 |

VTEP: leaf1 10.255.1.1, leaf3 10.255.1.3. 클라이언트 v1 10.10.10.11, 서버 v3 10.10.10.33:8080.

## Phase 0 — 베이스라인

```bash
$V1 ping -c3 10.10.10.33
$V1 ping -c3 -s 8000 -M do 10.10.10.33
$V1 ping -c3 -s 1422 -M do 10.10.10.33
$V1 ping -c3 -s 1423 -M do 10.10.10.33
$V1 curl -o /dev/null -w "%{time_total}s  %{speed_download} B/s\n" http://10.10.10.33:8080/video-large.bin
```

## Phase 1 — 정상 케이스

단일 플로우:

```bash
./cap.sh start hdr p1-single
$V1 curl -o /dev/null -w "src port %{local_port}  %{speed_download} B/s\n" http://10.10.10.33:8080/video-large.bin
./cap.sh stop
```

여러 번 받아보기 (캡처 없이 카운터로 빠르게). `FLUSH=1`이 없으면 전부 같은 스파인으로 간다 (아래 주의 참고):

```bash
for i in 1 2 3 4 5; do FLUSH=1 ./via.sh $V1 curl -s -o /dev/null -w "port %{local_port}\n" http://10.10.10.33:8080/video-small.mp4; done
```

> **주의 — 리눅스 VXLAN의 경로 캐시.** vxlan 드라이버는 원격 VTEP마다 경로를 캐시한다(dst_cache).
> 해시정책을 L4로 바꿔도 해시는 캐시가 비었을 때 한 번만 쓰이고, 그 뒤로는 leaf1→leaf3 VXLAN 전부가 같은 스파인을 탄다.
> `ip route flush cache`(=`FLUSH=1`)나 MTU 변경처럼 라우팅 세대가 바뀌는 일이 있어야 다시 고른다.
> 하드웨어 스위치는 패킷마다 해시하므로 이건 리눅스 소프트웨어 VTEP의 특성이다.

병렬 4개 (캐시 때문에 네 개가 한 스파인으로 몰린다):

```bash
./cap.sh start hdr p1-parallel
$V1 sh -c 'for i in 1 2 3 4; do curl -s -o /dev/null -w "port %{local_port} %{speed_download}\n" http://10.10.10.33:8080/video-large.bin & done; wait'
./cap.sh stop
```

풀 캡처 (작은 파일만):

```bash
./cap.sh start full p1-full
$V1 curl --limit-rate 15M -o /tmp/got.mp4 http://10.10.10.33:8080/video-small.mp4 && $V1 md5sum /tmp/got.mp4
./cap.sh stop
```

pcap은 윈도우 `clos-fabric\experiments\01-http-mtu\pcap\<태그>\`로 복사된다. Wireshark에서 볼 것:
- 4789 포트가 VXLAN으로 자동 해석되는지 (안 되면 Decode As → UDP 4789 → VXLAN)
- 패킷 하나의 계층 구조, Follow TCP Stream
- File → Export Objects → HTTP로 영상 복원 (끝의 FIN까지 잡혀야 나온다. 전송이 빠르면 tcpdump가 놓치므로 `curl --limit-rate 15M` 권장) → 재생, md5 비교 (윈도우: `certutil -hashfile <파일> MD5`)
- 스파인 한 대의 pcap만 열었을 때 복원이 되는지

## Phase 2 — MTU 장애

터미널 두 개를 쓰면 편하다.

```bash
# 터미널 A
./fault.sh inject spine1          # 주입 직전 스냅샷도 state/fault-before.txt 에 남는다
./cap.sh start hdr p2-fault
docker exec -it clab-clos-v1 curl -o /dev/null http://10.10.10.33:8080/video-large.bin   # 진행률 보기. 멈추면 Ctrl-C
# 여러 번 반복. 되는 시도와 안 되는 시도를 기록. 캐시 때문에 매번 비워야 섞인다:
for i in $(seq 8); do FLUSH=1 ./via.sh $V1 curl -s -m 10 -o /dev/null -w "port %{local_port} %{size_download}B
" http://10.10.10.33:8080/video-small.mp4; done
```

```bash
# 터미널 B (멈춰 있는 동안)
watch -n1 ./fault.sh status
docker exec clab-clos-v1 ss -ti dst 10.10.10.33
```

```bash
# 끝나면
./cap.sh stop
$V1 curl -s -m 10 -o /dev/null -w "%{size_download}B %{speed_download}B/s\n" http://10.10.10.33:8080/video-small.mp4   # 재현성
```

`fault.sh status`는 장애 인터페이스 양쪽 끝(spine1:eth3, leaf3:eth1)과 대조군(spine2:eth3, leaf3:eth2)을 같이 보여준다.
드랍이 어느 쪽 카운터에 잡히는지도 기록할 것.

## Phase 3 — 경계값

ping 프로세스를 새로 띄울 때마다 ICMP id가 바뀌어 해시가 달라진다.
`via.sh` 출력에서 요청·응답이 spine1을 탔는지 먼저 보고, spine1을 탄 회차만 결과로 친다.

```bash
./via.sh $V1 ping -c3 -W1 -s 1422 -M do 10.10.10.33
./via.sh $V1 ping -c3 -W1 -s 1423 -M do 10.10.10.33
```

spine1을 탈 때까지 반복:

```bash
for i in $(seq 10); do ./via.sh $V1 ping -c3 -W1 -s 1423 -M do 10.10.10.33 | grep -E "loss|spine"; echo; done
```

요청 방향(leaf1→spine1)과 응답 방향(leaf3→spine1)이 따로 해시된다는 점도 볼거리다.

## Phase 4 — 복구

```bash
./fault.sh restore
$V1 curl -o /dev/null -w "%{time_total}s  %{speed_download} B/s\n" http://10.10.10.33:8080/video-large.bin
./fault.sh status     # 몇 초 간격으로 두 번 보고 드랍이 멈췄는지
```

## 종료

```bash
./teardown.sh            # MTU 9500/1500, 해시 0으로 원복하고 값을 찍어 확인
PURGE=1 ./teardown.sh    # 1GB 테스트 파일까지 삭제
```

캡처가 남아 있으면 `pcap/`(WSL)과 윈도우 사본 둘 다 지운다. 윈도우 쪽 `pcap/`, `files/`, `state/`는 .gitignore 처리돼 있다.
