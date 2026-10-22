#!/usr/bin/env bash
# K8s + Ceph 스토리지망 기동: 노드 이미지 빌드 → 기존 clos 랩 정리 → 배포 → 리프 오버레이 → EVPN
set -eu
cd "$(dirname "$0")"
N=clab-clos

echo "[*] 노드 이미지 빌드 (clos-k8s-node)"
docker build -q -t clos-k8s-node:latest ./node >/dev/null 2>&1 || docker build -t clos-k8s-node:latest ./node

echo "[*] 기존 'clos' 랩 정리(있으면)"
for t in ../clos.clab.yml ../monitoring/clos-mon.clab.yml clos-k8s.clab.yml; do
  containerlab destroy -t $t --cleanup >/dev/null 2>&1 || true
done

echo "[*] 토폴로지 배포 (라우터 6 + 베이스 서버 6 + 워커 3 + Ceph 3)"
containerlab deploy -t clos-k8s.clab.yml >/dev/null 2>&1 || containerlab deploy -t clos-k8s.clab.yml

echo "[*] 리프 데이터플레인 (VRF/VXLAN/브리지) + EVPN 설정"
for i in 1 2 3 4; do
  docker exec $N-leaf$i sh /k8s/overlay.sh 10.255.1.$i 2>&1 | grep -v done
  docker exec $N-leaf$i sh -c "sed 's/@AS@/6501$i/; s/@RID@/10.255.1.$i/' /k8s/frr-overlay.conf > /tmp/overlay.conf && vtysh -f /tmp/overlay.conf" >/dev/null 2>&1
done
# 스파인: EVPN 경로를 중계만 한다. next-hop을 자기 것으로 바꾸면 터널이 깨진다
for i in 1 2; do
  docker exec $N-spine$i vtysh -c "conf t" -c "router bgp 6500$i" -c "address-family l2vpn evpn" \
    -c "neighbor FABRIC activate" -c "neighbor FABRIC attribute-unchanged next-hop" >/dev/null
done
# 붙어 있는 세션에 주소군을 새로 켜면 NoNeg → 세션을 한 번 끊었다 붙여야 협상된다
for n in spine1 spine2 leaf1 leaf2 leaf3 leaf4; do
  docker exec $N-$n vtysh -c "clear bgp *" >/dev/null 2>&1 || true
done

echo "[*] BGP·EVPN 수렴 대기"
sleep 20
echo "준비 완료. 점검: ./test.sh"
