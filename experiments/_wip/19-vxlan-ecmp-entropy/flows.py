#!/usr/bin/env python3
"""두 업링크 캡처에서 VXLAN 안쪽 흐름(출발 포트)이 어느 링크로 갔는지 맞춘다.

  flows.py <eth1.pcap> <eth2.pcap> [inner_src_ip]
  → 'sport  link  outer_sport  pkts' 줄들 + 마지막 줄 'SUMMARY eth1=N eth2=M both=K'
"""
import collections, socket, struct, sys


def packets(fn):
    f = open(fn, "rb")
    gh = f.read(24)
    end = "<" if gh[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
    while True:
        h = f.read(16)
        if len(h) < 16:
            return
        _, _, incl, _ = struct.unpack(end + "IIII", h)
        yield f.read(incl)


def inner_flows(fn, src):
    r = collections.defaultdict(lambda: [0, set()])
    for p in packets(fn):
        if len(p) < 14 + 20 + 8 + 8 + 14 + 24 or p[12:14] != b"\x08\x00" or p[23] != 17:
            continue
        u = 14 + (p[14] & 15) * 4
        if struct.unpack("!H", p[u + 2:u + 4])[0] != 4789:
            continue
        osport = struct.unpack("!H", p[u:u + 2])[0]
        i = u + 8 + 8 + 14
        if p[i - 2:i] != b"\x08\x00":
            continue
        if src and socket.inet_ntoa(p[i + 12:i + 16]) != src:
            continue
        proto = p[i + 9]
        l4 = i + (p[i] & 15) * 4
        if proto not in (6, 17):
            continue
        sport, dport = struct.unpack("!HH", p[l4:l4 + 4])
        if proto == 6 and dport < 5000 and sport < 5000:
            continue
        key = sport
        r[key][0] += 1
        r[key][1].add(osport)
    return r


if __name__ == "__main__":
    src = sys.argv[3] if len(sys.argv) > 3 else None
    a, b = inner_flows(sys.argv[1], src), inner_flows(sys.argv[2], src)
    n1 = n2 = both = 0
    for k in sorted(set(a) | set(b)):
        if k in a and k in b:
            both += 1; link = "both"
        elif k in a:
            n1 += 1; link = "eth1"
        else:
            n2 += 1; link = "eth2"
        osp = sorted((a.get(k, [0, set()])[1]) | (b.get(k, [0, set()])[1]))
        print(f"{k:6d} {link:5s} {','.join(map(str, osp[:3]))} {a.get(k, [0])[0] + b.get(k, [0])[0]}")
    print(f"SUMMARY eth1={n1} eth2={n2} both={both}")
