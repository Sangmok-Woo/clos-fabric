#!/usr/bin/env python3
"""Gratuitous ARP 를 보낸다 (VM 이 옮겨진 뒤 하이퍼바이저가 보내는 것과 같은 모양).

  garp.py <dev> <ip> [횟수=1] [간격초=0]
"""
import socket, struct, sys, time

dev, ip = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 1
gap = float(sys.argv[4]) if len(sys.argv) > 4 else 0
mac = bytes.fromhex(open(f"/sys/class/net/{dev}/address").read().strip().replace(":", ""))
a = socket.inet_aton(ip)
frame = b"\xff" * 6 + mac + b"\x08\x06" + struct.pack("!HHBBH", 1, 0x0800, 6, 4, 1) + mac + a + b"\x00" * 6 + a
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind((dev, 0))
for i in range(n):
    s.send(frame)
    if i < n - 1:
        time.sleep(gap)
