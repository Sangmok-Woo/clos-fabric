#!/usr/bin/env bash
# 0단계: WSL 커널(6.6.87.2)에 빠진 모듈 두 개를 빌드해서 올린다. WSL root 셸에서 직접 실행한다.
#   rdma_rxe       Soft-RoCE 드라이버 (CONFIG_RDMA_RXE is not set)
#   crc32_generic  rxe 가 ICRC 계산에 쓰는 crc32 (CONFIG_CRYPTO_CRC32 is not set) — 없으면 rdma link add 가 ENOENT
# 커널 전체는 빌드하지 않는다. 이미 설치된 모듈들이 가져다 쓰는 심볼 버전(CRC)을 모아 Module.symvers 를 만든다.
# 컴파일은 도커 컨테이너 안에서 한다 (WSL 의 apt 상태와 상관없이).
set -e
K=/root/kbuild; V=$(uname -r); TAG=linux-msft-wsl-${V%%-*}
mkdir -p $K && cd $K
[ -f src.tgz ] || curl -sSL -o src.tgz https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/$TAG.tar.gz
[ -f linux/Makefile ] || { mkdir -p linux; tar xzf src.tgz -C linux --strip-components=1; }
zcat /proc/config.gz > linux/.config
sed -i 's/# CONFIG_RDMA_RXE is not set/CONFIG_RDMA_RXE=m/' linux/.config
for k in $(find /lib/modules/$V/kernel -name '*.ko*'); do modprobe --dump-modversions $k 2>/dev/null; done \
  | sort -u -k2 | awk '{print $1"\t"$2"\tvmlinux\tEXPORT_SYMBOL\t"}' > symvers.host
mkdir -p crc32mod && cp linux/crypto/crc32_generic.c crc32mod/ && echo 'obj-m := crc32_generic.o' > crc32mod/Makefile
docker run --rm --dns 8.8.8.8 -v $K:/k -w /k/linux ubuntu:24.04 bash -c '
  apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q gcc make flex bison libelf-dev libssl-dev bc dwarves python3 >/dev/null 2>&1
  make olddefconfig >/dev/null && make -j2 modules_prepare >/dev/null
  cp /k/symvers.host Module.symvers; make -j2 M=drivers/infiniband/sw/rxe KBUILD_MODPOST_WARN=1 modules
  cp /k/symvers.host /k/crc32mod/Module.symvers; make M=/k/crc32mod KBUILD_MODPOST_WARN=1 modules'
# ib_umem_* 는 ib_uverbs 에 있다 — 먼저 올리지 않으면 insmod 가 Unknown symbol
modprobe ib_core; modprobe ib_uverbs; modprobe rdma_ucm; modprobe udp_tunnel; modprobe ip6_udp_tunnel
insmod $K/crc32mod/crc32_generic.ko
insmod $K/linux/drivers/infiniband/sw/rxe/rdma_rxe.ko
lsmod | grep -E 'rdma_rxe|crc32_generic'
