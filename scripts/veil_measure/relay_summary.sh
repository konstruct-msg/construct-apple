#!/bin/zsh
# Per-hour totals of a VEIL relay's per-minute `connection summary` — todo 311 step 1.
#
# The summary carries counts only (no address, no identifier): admitted tunnels, connections
# that never authenticated (probes, cover-site visits, health checks), handshake failures, and —
# from construct-veil #28 on — tunnels open at once and closed tunnels by lifetime.
#
#   scripts/veil_measure/relay_summary.sh <ssh-key> <user@host> [since, default 24h]
#   e.g. scripts/veil_measure/relay_summary.sh ~/.ssh/veil_primary subwhale@<relay> 48h
#
# The container's log starts at its last recreate; `since` cannot reach past that.
set -u
key=$1 host=$2 since=${3:-24h}
ssh -i $key -o BatchMode=yes -o ConnectTimeout=15 $host \
  "docker logs --since $since veil-front-relay 2>&1 | grep 'connection summary'" |
  LC_ALL=C sed -E 's/\x1b\[[0-9;]*m//g' |
  python3 -I -c '
import re, sys
from collections import defaultdict
keys = ["completed", "handshake_failed", "tunnels", "open_peak", "closed_lt_1m", "closed_lt_10m", "closed_ge_10m"]
hours = defaultdict(lambda: defaultdict(int))
minutes = defaultdict(int)
for line in sys.stdin:
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d)", line)
    if not m:
        continue
    h = m.group(1).replace("T", " ") + ":00"
    minutes[h] += 1
    for k, v in re.findall(r"(\w+)=(\d+)", line):
        if k == "open_peak":
            hours[h][k] = max(hours[h][k], int(v))
        elif k in keys:
            hours[h][k] += int(v)
if not hours:
    print("no connection summary in the window (idle relay, or the container is newer)")
    sys.exit(1)
print("hour (UTC)         min " + " ".join(f"{k:>14}" for k in keys))
tot = defaultdict(int)
for h in sorted(hours):
    print(f"{h}  {minutes[h]:>3} " + " ".join(f"{hours[h][k]:>14}" for k in keys))
    for k in keys:
        tot[k] = max(tot[k], hours[h][k]) if k == "open_peak" else tot[k] + hours[h][k]
print("total                   " + " ".join(f"{tot[k]:>14}" for k in keys))
print("(open_peak: the most tunnels open at once in that hour — the anonymity set of a reconnect)")
'
