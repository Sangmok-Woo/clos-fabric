#!/usr/bin/env bash
# Ansible 실행기. WSL 에서 root 로:  ./ansible/run.sh <playbook> [옵션...]
#   ./ansible/run.sh check.yml
#   ./ansible/run.sh bfd.yml -e bfd_enabled=false
#   ./ansible/run.sh evpn.yml --check --diff
# 왜 감싸나:
#  - /mnt/c 는 world-writable 이라 ansible.cfg 가 무시된다 → ANSIBLE_CONFIG 로 직접 지정
#  - Ansible 은 wsm0218 의 venv 에 있는데, containerlab·docker 는 root 로 돌린다
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
VENV=${ANSIBLE_VENV:-/home/wsm0218/.venvs/ansible}
export ANSIBLE_CONFIG=$HERE/ansible.cfg
cd "$HERE"
pb=$1; shift
exec "$VENV/bin/ansible-playbook" "$pb" "$@"
