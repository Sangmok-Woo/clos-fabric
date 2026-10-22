# K8s 노드·Ceph 노드 공용 이미지. FRR(워커의 BGP 스피커) + iputils(ping -M do로 점보 경로 확인)
# busybox ping에는 -M이 없어 1500 경로의 점보 차단을 확인할 수 없다
FROM quay.io/frrouting/frr:10.2.1
RUN apk add --no-cache iputils
