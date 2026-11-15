#!/usr/bin/env bash
# Positive control: capture traffic made to be caught, and require the analyzer to catch it.
# Run before every stand run that is meant to prove a green — a red that cannot appear proves
# nothing (AGENTS.md rule 9).
#
#   control.sh      # exit 0 = the analyzer finds every planted value and flow, and no other value
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$HERE/../.." && pwd)/logs/pcap_stand"
name="control-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/$name"

"$HERE/capture.sh" start "$name"
trap '"$HERE/capture.sh" stop "$name" >/dev/null 2>&1 || true' EXIT
sleep 1
python3 -I "$HERE/control.py" "$OUT/$name"
sleep 2
"$HERE/capture.sh" stop "$name"
trap - EXIT

pcap="$OUT/$name.pcap"
run() { python3 -I "$HERE/analyze.py" "$@" >"$OUT/$name/$1.txt" 2>&1 || true; cat "$OUT/$name/$1.txt"; }
run t1 "$pcap" --needles "$OUT/$name/control-needles.json"
run t2 "$pcap" --host example.com
run t3 "$pcap" --host example.com

python3 -I - "$OUT/$name" <<'EOF'
import json, re, sys
d = sys.argv[1]
exp = json.load(open(f"{d}/control-expect.json"))
t1, t2, t3 = (open(f"{d}/{t}.txt").read() for t in ("t1", "t2", "t3"))
bad = []
for n in exp["t1"]:
    if f"RED t1: {n} " not in t1:
        bad.append(f"t1 missed {n}")
for n in exp["t1_absent"]:
    if f"RED t1: {n} " in t1:
        bad.append(f"t1 found {n}, which was never sent")
m = re.search(r"t2: \d+ flows judged, (\d+) without a handshake", t2)
if not m or int(m.group(1)) != exp["t2_red_flows"]:
    bad.append(f"t2: expected {exp['t2_red_flows']} flow(s) without a handshake, got {m.group(1) if m else 'no summary'}")
for f in exp["t3"]:
    if f"RED t3: {f}=" not in t3:
        bad.append(f"t3 missed a repeated {f}")
if bad:
    print("CONTROL FAILED:\n  " + "\n  ".join(bad))
    sys.exit(1)
print("CONTROL OK: every planted value and flow was caught, the unsent one was not")
EOF
