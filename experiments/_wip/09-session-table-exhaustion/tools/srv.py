#!/usr/bin/env python3
# srv 용 TCP 서버. 80·8080 을 연다.
#   "GET ..."  → HTTP 200 한 번 주고 닫는다 (curl 용)
#   "PING"     → "PONG" 을 돌려주고 연결은 유지 (붙잡힌 연결이 살아 있는지 확인용)
#   아무 말 없으면 그대로 붙잡고 있는다. 상대가 FIN 을 보내면 같이 닫는다.
import asyncio
async def handle(r, w):
    try:
        while True:
            line = await r.readline()
            if not line:
                break
            if line.startswith(b"GET"):
                body = b"ok\n"
                w.write(b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n" + body)
                await w.drain(); break
            if line.startswith(b"PING"):
                w.write(b"PONG\n"); await w.drain()
    except Exception:
        pass
    finally:
        w.close()
async def main():
    s = [await asyncio.start_server(handle, "0.0.0.0", p, backlog=1024) for p in (80, 8080)]
    await asyncio.gather(*(x.serve_forever() for x in s))
asyncio.run(main())
