#!/usr/bin/env bash
# 패킷 하나의 상세 트리를 텍스트로 (Wireshark 상세 창과 같은 내용). 윈도우 Git Bash 에서 실행.
#   detail.sh <pcap> <프레임번호> [프로토콜 ...]     예: detail.sh capture/x.pcap 395 ip tcp
# 프로토콜을 주면 그 계층만 펼친다(tshark -O).
T="/c/Program Files/Wireshark/tshark.exe"
f=$1; n=$2; shift 2
o=$(IFS=,; echo "$*")
"$T" -C lab-chapters -r "$f" -Y "frame.number==$n" -V ${o:+-O $o} 2>/dev/null | sed 's/\r$//'
