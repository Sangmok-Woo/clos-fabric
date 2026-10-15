#!/usr/bin/env bash
# 랩 띄우기: configs/ → state/<노드>/ (쓰기 가능한 /etc/frr) → containerlab deploy
set -eu
cd "$(dirname "$0")"
rm -rf state; mkdir -p state
for n in spine1 spine2 leaf1 leaf2; do
  mkdir -p state/$n; cp configs/daemons configs/vtysh.conf configs/$n/frr.conf state/$n/
  chmod 777 state/$n; chmod 666 state/$n/*
done
containerlab deploy -t grlab.clab.yml --reconfigure
