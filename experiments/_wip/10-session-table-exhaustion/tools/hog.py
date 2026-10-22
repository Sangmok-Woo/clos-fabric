#!/usr/bin/env python3
# 연결을 N개 열어 붙잡고 있는 클라이언트 (cli1·cli2 에서 실행).
#   hog.py <dst> <port> <N> [--src 10.9.1.10-19] [--ctimeout 3] [--hold 600] [--ping 1]
# 동시에 N개 connect 를 걸고(각 ctimeout 초 제한), 성공 수를 출력한다.
# 붙잡은 연결엔 --ping 초마다 PING 을 보내 PONG 수를 센다 → "alive x/y".
# --hold 초가 지나면(또는 SIGTERM) 전부 정상 종료(FIN)한다.
import asyncio, sys, time, argparse, signal
ap = argparse.ArgumentParser()
ap.add_argument("dst"); ap.add_argument("port", type=int); ap.add_argument("n", type=int)
ap.add_argument("--src", default=""); ap.add_argument("--ctimeout", type=float, default=3)
ap.add_argument("--hold", type=float, default=600); ap.add_argument("--ping", type=float, default=1)
a = ap.parse_args()
srcs = []
if a.src:
    base, rng = a.src.rsplit(".", 1)
    lo, hi = (rng.split("-") + [rng])[:2]
    srcs = [f"{base}.{i}" for i in range(int(lo), int(hi) + 1)]
def log(*x):
    print(time.strftime("%H:%M:%S"), *x, flush=True)
async def one(i):
    kw = {"local_addr": (srcs[i % len(srcs)], 0)} if srcs else {}
    try:
        return await asyncio.wait_for(asyncio.open_connection(a.dst, a.port, **kw), a.ctimeout)
    except Exception as e:
        return None
async def main():
    t0 = time.time()
    res = await asyncio.gather(*(one(i) for i in range(a.n)))
    ok = [c for c in res if c]
    log(f"connect {len(ok)}/{a.n} ok  ({time.time()-t0:.2f}s, ctimeout {a.ctimeout}s)")
    stop = asyncio.Event()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, stop.set)
    end = time.time() + a.hold
    while time.time() < end and not stop.is_set():
        alive = 0
        for r, w in ok:
            try:
                w.write(b"PING\n"); await w.drain()
                if (await asyncio.wait_for(r.readline(), 2)).startswith(b"PONG"):
                    alive += 1
            except Exception:
                pass
        log(f"alive {alive}/{len(ok)}")
        try:
            await asyncio.wait_for(stop.wait(), a.ping)
        except asyncio.TimeoutError:
            pass
    for r, w in ok:
        w.close()
    await asyncio.sleep(0.5)
    log("closed")
asyncio.run(main())
