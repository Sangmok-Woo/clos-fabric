#!/usr/bin/env python3
"""pcap 의 IPv4 TOS 를 센다. VXLAN(UDP 4789)이면 (바깥 TOS, 안쪽 TOS) 짝으로.

  tos.py <pcap> [src_ip]      → 'outer=0x02 inner=0x02  12' 같은 줄 (VXLAN 이 아니면 outer=- )
"""
import collections, socket, struct, sys

ECN = {0: "Not-ECT", 1: "ECT(1)", 2: "ECT(0)", 3: "CE"}


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


def tos_pairs(fn, src=None):
    c = collections.Counter()
    for p in packets(fn):
        if len(p) < 34 or p[12:14] != b"\x08\x00":
            continue
        ihl = (p[14] & 15) * 4
        o_tos, proto = p[15], p[23]
        o_src = socket.inet_ntoa(p[26:30])
        u = 14 + ihl
        if proto == 17 and len(p) >= u + 4 and struct.unpack("!H", p[u + 2:u + 4])[0] == 4789:
            i = u + 8 + 8 + 14                      # UDP 8 + VXLAN 8 + 안쪽 이더넷 14
            if len(p) < i + 20 or p[i - 2:i] != b"\x08\x00":
                continue
            i_src = socket.inet_ntoa(p[i + 12:i + 16])
            if src and i_src != src:
                continue
            c[(o_tos, p[i + 1])] += 1
        else:
            if src and o_src != src:
                continue
            c[(None, o_tos)] += 1
    return c


if __name__ == "__main__":
    for (o, i), n in sorted(tos_pairs(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None).items(), key=lambda x: (x[0][0] or 0, x[0][1])):
        os_ = "-" if o is None else f"0x{o:02x}({ECN[o & 3]})"
        print(f"outer={os_:<16} inner=0x{i:02x}({ECN[i & 3]})  {n}")
