#!/bin/bash
# 랩 띄우기. --reconfigure 는 veth 정리를 덜 해 링크가 안 생기는 일이 있어 destroy→deploy 로.
cd "$(dirname "$0")"; . ./lib.sh
containerlab destroy -t bgp.clab.yml --cleanup >/dev/null 2>&1
containerlab deploy  -t bgp.clab.yml
wait_up 90 && harden && ./world.sh
