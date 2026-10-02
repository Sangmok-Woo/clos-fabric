#!/usr/bin/env bash
. "$(dirname "$0")/../_tools/lab.sh"
nsx h4 iptables -D INPUT -p udp --dport 53 -j DROP 2>/dev/null
dx h4 pkill -x dnsmasq
dx h1 sh -c 'echo nameserver 8.8.8.8 > /etc/resolv.conf'
pkill -f "$CAPDIR" 2>/dev/null; echo 원복
