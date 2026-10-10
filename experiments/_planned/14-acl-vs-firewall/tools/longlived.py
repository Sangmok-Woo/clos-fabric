# 연결 하나를 열어 두고 1초마다 한 줄 주고받는다. python3 longlived.py <ip> <port> <secs>
import socket, sys, time
ip, port, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.create_connection((ip, port), timeout=2)
for i in range(secs):
    try:
        s.sendall(b"ping\n"); r = s.recv(16)
        print(time.strftime("%H:%M:%S"), "기존 연결 응답", "OK" if r else "끊김", flush=True)
    except OSError as e:
        print(time.strftime("%H:%M:%S"), "기존 연결 실패", e, flush=True)
    time.sleep(1)
