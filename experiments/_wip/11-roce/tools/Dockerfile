# h서버 netns 에 붙여 쓰는 RDMA 도구 상자 (rdma-core, perftest, iproute2 의 rdma 명령)
FROM ubuntu:24.04
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      iproute2 rdma-core ibverbs-utils ibverbs-providers rdmacm-utils perftest infiniband-diags \
      iputils-ping tcpdump procps iperf3 && rm -rf /var/lib/apt/lists/*
