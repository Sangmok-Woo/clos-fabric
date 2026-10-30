# 2026-10-30 — 내 노트북의 경비실 (IOMMU · ACS · ATS)

> **한 줄** — 노트북에도 IOMMU가 있고, ATS는 내장 그래픽 하나만 지원한다. 내장 그래픽은 오디오·USB와 칸막이 없이 붙어 있다.

오늘은 패킷이 아니라 PC 안쪽을 봤다. 랩은 쓰지 않았다. Lenovo 82XR, Ryzen 5 7530U, Windows 10 + WSL2.

```
CPU ┬ 00:02.1 루트 포트 ─ SD 리더
    ├ 00:02.2 루트 포트 ─ Wi-Fi
    ├ 00:02.4 루트 포트 ─ NVMe SSD
    └ 00:08.1 루트 포트 ─ 04:00.0~6  내장 그래픽 + 오디오 + 보안 + USB (한 장치에 7개 기능)
```

| 낱말 | 비유 | 하는 일 |
|---|---|---|
| IOMMU | 경비실 | 장치가 메모리 어디까지 만질 수 있는지 막는다 |
| ACS | 복도의 검색대 | 장치끼리 경비실을 거치지 않고 통신하는 걸 막는다 |
| ATS | 출입증 | 장치가 주소 변환 결과를 받아 두고 직접 쓴다 |

---

## 장면 1 — 경비실이 있나? 있다

- 펌웨어 ACPI 표에 `IVRS`가 있다. AMD IOMMU가 있다는 신고서다
- Windows Device Guard의 `AvailableSecurityProperties`에 `3`(DMA 보호)이 있다
- WSL의 `dmesg`에도 `AMD-Vi`가 찍히지만 WSL 커널 메시지라 증거로 쓰지 않았다

## 장면 2 — 그래픽은 어느 구역에? 혼자가 아닐 듯 (추정)

| 위치 | 장치 | ACS 레지스터 |
|---|---|---|
| 00:02.1, .2, .4, 00:08.1 | 루트 포트 4개 | **95** (0x5F) |
| 04:00.0~6 | 내장 그래픽 외 6개 기능 | **0** |

- 루트 포트에는 검색대가 있어서 SD 리더, Wi-Fi, SSD는 따로 떼어낼 수 있을 것이다
- 04:00.x는 값이 0이다. Linux라면 일곱 개가 한 그룹으로 묶일 것으로 본다
- 이 표는 지원 여부다. 실제로 켜져 있는지는 Windows 값으로 알 수 없다

## 장면 3 — 출입증은 누가? 내장 그래픽 하나

| ATS | 장치 |
|---|---|
| **지원 (1)** | Radeon 내장 그래픽 |
| 미지원 (13) | 루트 포트 4, SD 리더, Wi-Fi, SSD, 오디오·보안·USB 6 |
| 값 없음 (14) | 호스트 브리지 등 |

가이드는 거의 안 나올 거라고 했다. 드문 건 맞지만 0개는 아니어서, ATS가 서버 전용은 아니다.

---

## 쉽게 말하면

건물에 경비실이 있고, 방 대부분은 입구에 검색대가 있다. 내장 그래픽은 오디오·USB와 한 방을 쓰는 것으로 보이고, 출입증은 내장 그래픽만 갖고 있다. 방 배정표(IOMMU 그룹)는 아직 직접 못 봤다.

## 파일

| 파일 | 내용 |
|---|---|
| [raw/pci-windows.txt](raw/pci-windows.txt) | PCI 장치 28개의 ACS·ATS 값 |
| [raw/firmware-windows.txt](raw/firmware-windows.txt) | CPU, Device Guard, ACPI 표 |
| [raw/wsl.txt](raw/wsl.txt) | WSL에서 돌린 가이드 명령 결과 |

<details><summary>측정 때 알아둔 것</summary>

- 가이드는 Linux 부팅과 RTX 4060 Ti 기준이다. 이 노트북은 둘 다 해당이 없어서 Windows 값으로 대신했다. WSL에서는 IOMMU 그룹이 0개로 나온다
- 그룹을 직접 보려면 Linux 라이브 USB로 부팅해서 `/sys/kernel/iommu_groups`를 본다
- 값 읽기: `Get-PnpDeviceProperty`의 `DEVPKEY_PciDevice_AcsCapabilityRegister`, `DEVPKEY_PciDevice_AtsSupport`. 키를 하나씩 조회하면 2분을 넘겨서 장치별로 한 번에 읽었다
- 04:00.x는 `AcsSupport=0`(있음)인데 레지스터는 0이다. 해석이 불확실해서 레지스터 값을 기준으로 삼았다
- ACPI 표 목록은 `EnumSystemFirmwareTables`로 읽었다. 스크립트는 `raw/*.ps1`, `raw/collect-wsl.sh`
</details>
