#!/usr/bin/env python3
# 단방향 UDP 탐침. ping 은 왕복이라 어느 방향이 끊겼는지 못 가른다.
#   send <목적지> <포트> <흐름수> <초> <출발포트시작> <헤더파일>
#       흐름(출발 포트)마다 10ms 간격. 보내기 실패(경로 없음)도 순번은 올라가 손실로 잡힌다
#   recv <포트> <기록파일> <초>          한 줄 = "흐름 순번 보낸시각" (보낸 시각으로 WSL 멈춤을 가려낸다)
import socket, struct, sys, time

IV = 0.01
mode = sys.argv[1]
if mode == "send":
    dst, port, n, dur, base, hdr = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]), int(sys.argv[6]), sys.argv[7]
    socks = []
    for i in range(n):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("", base + i))
        socks.append(s)
    t0 = time.time(); seq = 0
    while True:
        tgt = t0 + seq * IV
        now = time.time()
        if tgt > t0 + dur:
            break
        if tgt > now:
            time.sleep(tgt - now)
        for i, s in enumerate(socks):
            try:
                s.sendto(struct.pack("!HId", i, seq, time.time()) + b"x" * 18, (dst, port))
            except OSError:
                pass
        seq += 1
    with open(hdr, "w") as f:
        f.write(f"{t0:.6f} {seq} {n}\n")
elif mode == "recv":
    port, out, dur = int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("", port)); s.settimeout(0.5)
    end = time.time() + dur
    with open(out, "w") as f:
        while time.time() < end:
            try:
                d, _ = s.recvfrom(64)
            except socket.timeout:
                continue
            i, seq, ts = struct.unpack("!HId", d[:14])
            f.write(f"{i} {seq} {ts:.4f}\n")
