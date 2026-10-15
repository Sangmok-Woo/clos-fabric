#!/usr/bin/env bash
# 랩 지우기 (내 것만: clab-grlab-*, 관리망 grlab-mgmt)
cd "$(dirname "$0")"
containerlab destroy -t grlab.clab.yml --cleanup
docker network rm grlab-mgmt 2>/dev/null
docker ps -a --format '{{.Names}}' | grep '^clab-grlab-' && echo "남은 컨테이너 있음" || echo "grlab 컨테이너 없음"
