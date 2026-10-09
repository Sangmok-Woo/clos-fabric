# 연결을 n개 열어 secs초 붙잡는다 (conntrack 테이블 채우기). python3 hold.py <ip> <port> <n> <secs>
import socket, sys, time
ip, port, n, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
socks, fail = [], 0
for i in range(n):
    s = socket.socket(); s.settimeout(2)
    try: s.connect((ip, port)); socks.append(s)
    except OSError: fail += 1
print(f"열기 성공 {len(socks)} / 실패 {fail}", flush=True)
time.sleep(secs)
