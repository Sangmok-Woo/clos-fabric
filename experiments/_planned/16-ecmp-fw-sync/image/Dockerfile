# 16장 이미지: 14장의 fwlab:1 + conntrackd (방명록 동기화 데몬)
FROM fwlab:1
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends conntrackd \
 && rm -rf /var/lib/apt/lists/*
