#!/usr/bin/env bash
# 랩 기동/철거.  사용법: ./scripts/deploy.sh up | down | redeploy
set -eu
cd "$(dirname "$0")/.."
case "${1:-up}" in
  up)       containerlab deploy -t clos.clab.yml ;;
  down)     containerlab destroy -t clos.clab.yml --cleanup ;;
  redeploy) containerlab destroy -t clos.clab.yml --cleanup || true
            containerlab deploy -t clos.clab.yml ;;
  *) echo "up | down | redeploy"; exit 1 ;;
esac
