#!/usr/bin/env bash
# 모니터링 토폴로지 철거. (베이스 랩으로 돌아가려면 ../scripts/deploy.sh up)
set -eu
cd "$(dirname "$0")"
containerlab destroy -t clos-mon.clab.yml --cleanup
