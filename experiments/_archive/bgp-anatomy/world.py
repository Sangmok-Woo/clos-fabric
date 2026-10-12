# world.sh 가 부른다: vtysh "show bgp ipv4 unicast <p> json" 출력 → 한 줄 요약
import json, sys
r = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
best = [x for x in d.get("paths", []) if x.get("bestpath", {}).get("overall")]
if not best:
    print(f"{r:<7}(경로 없음)")
    sys.exit()
b = best[0]
path = b.get("aspath", {}).get("string", "")
nh = (b.get("nexthops") or [{}])[0].get("ip", "-")
origin = "AS" + (path.split()[-1] if path else r[1:])
rpki = b.get("rpkiValidationState", "")
print(f"{r:<7}{d.get('prefix', ''):<19}{nh:<14}{b.get('locPrf', '-'):<5}{origin:<7}{rpki:<10}{path or '(내 것)'}")
