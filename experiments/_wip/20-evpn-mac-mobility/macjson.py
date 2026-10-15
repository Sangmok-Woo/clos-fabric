#!/usr/bin/env python3
"""FRR 'show evpn mac vni N mac M json' → 한 줄 요약 (환경변수 MAC)."""
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("없음"); sys.exit()
m = d.get(os.environ.get("MAC", ""), d)
if not m:
    print("없음"); sys.exit()
print(f"{m.get('type', '?')} VTEP={m.get('remoteVtep', '-')} 순번(local/remote)={m.get('localSequence', '?')}/{m.get('remoteSequence', '?')} 중복={m.get('isDuplicate', m.get('duplicate', '?'))}")
