# 14장 전 노드 공통 이미지. 노드마다 도구가 같아야 "도구 차이"가 변수에서 빠진다.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      iproute2 iputils-ping nftables conntrack tcpdump hping3 curl socat \
      dnsutils dnsmasq-base python3 procps netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
