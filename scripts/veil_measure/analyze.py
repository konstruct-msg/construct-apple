#!/usr/bin/env python3
"""How often a client opens a new TLS connection to a VEIL relay — todo 311 step 1.

Under AUTH v4 every new connection to a relay spends one token (construct-docs
decisions/veil-relay-sees-no-stable-device-id.md §5: epoch 7 days, batch 50). This reads app
logs and reports how many connections a client opens per hour and per day, how they cluster,
and how fast a new connection follows a network change — the timing a relay could link a
device's two IPs by.

Input: app log files (`Documents/Logs/current.log`, `1.log` … from the app container or a log
export, or what collect.sh gathered). Several files and several clients may be given; lines are
merged, de-duplicated and split by file label (`label=path`, default: the file name).

    scripts/veil_measure/analyze.py ~/Code/veil-measure/*.log
    scripts/veil_measure/analyze.py iphone=~/Downloads/logs/current.log iphone=~/Downloads/logs/1.log

Reads only VEIL / transport event lines; message contents are not in these logs and are not
printed. Exit 1 when no connection line was found (nothing measured).
"""
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from statistics import median

LINE = re.compile(r"^\[(?P<ts>\d{4}-\d\d-\d\dT[\d:.]+Z?)\] \[(?P<level>\w+)\] \[(?P<cat>[^\]]*)\] (?P<msg>.*)$")

# One new TLS connection to a relay over the native-TLS path (VeilFrontExternalDialer): the
# exporter is derived once per connection, right before AUTH.
CONNECTION = "VEIL native-TLS: exporter derived"
# The rustls fallback opens connections that log nothing per connection — counted as a warning.
FALLBACK = ("native-TLS dial failed/timeout, falling back to rustls",)
DIAL_FAILED = ("per-connection dial failed",)
NETWORK_CHANGE = ("Network path changed",)
MODE_OFF = ("VEIL startup skipped — mode is off", "VEIL enable skipped — mode is off")

BATCH = 50
EPOCH_DAYS = 7


def parse_ts(s: str) -> datetime:
    s = s.rstrip("Z")
    fmt = "%Y-%m-%dT%H:%M:%S.%f" if "." in s else "%Y-%m-%dT%H:%M:%S"
    return datetime.strptime(s, fmt)


def read(args):
    events = defaultdict(set)  # label -> {(ts, kind, msg)}
    for arg in args:
        label, _, path = arg.rpartition("=") if "=" in arg else ("", "", arg)
        label = label or path.rsplit("/", 1)[-1].split(".")[0]
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        except OSError as e:
            print(f"skip {path}: {e}", file=sys.stderr)
            continue
        for line in lines:
            m = LINE.match(line)
            if not m:
                continue
            msg = m["msg"]
            if CONNECTION in msg:
                kind = "conn"
            elif any(k in msg for k in FALLBACK):
                kind = "fallback"
            elif any(k in msg for k in DIAL_FAILED):
                kind = "dial_failed"
            elif any(k in msg for k in NETWORK_CHANGE):
                kind = "net"
            elif any(k in msg for k in MODE_OFF):
                kind = "mode_off"
            else:
                continue
            # The message is kept only to de-duplicate overlapping files; it is not printed.
            events[label].add((parse_ts(m["ts"]), kind, msg))
    return {k: sorted(v) for k, v in events.items()}


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


def fmt_s(sec: float) -> str:
    if sec < 120:
        return f"{sec:.0f} s"
    if sec < 7200:
        return f"{sec / 60:.1f} min"
    return f"{sec / 3600:.1f} h"


def report(label, evs):
    conns = [t for t, k, _ in evs if k == "conn"]
    nets = [t for t, k, _ in evs if k == "net"]
    kinds = defaultdict(int)
    for _, k, _ in evs:
        kinds[k] += 1
    print(f"\n== {label}")
    if not conns:
        print("  no relay connection lines — VEIL off, not used, or the rustls path (see below)")
        for k in ("fallback", "dial_failed", "mode_off", "net"):
            if kinds[k]:
                print(f"  {k}: {kinds[k]}")
        return False
    span = (max(t for t, _, _ in evs) - min(t for t, _, _ in evs)).total_seconds() or 1
    hours = span / 3600
    per_day = len(conns) / span * 86400
    print(f"  covered: {min(conns):%Y-%m-%d %H:%M} … {max(conns):%Y-%m-%d %H:%M} UTC ({fmt_s(span)} of log)")
    print(f"  relay connections: {len(conns)}  →  {len(conns) / hours:.1f}/h, ~{per_day:.0f}/day at this rate")
    print(
        f"  tokens per {EPOCH_DAYS}-day epoch at this rate: ~{per_day * EPOCH_DAYS:.0f} "
        f"(batch {BATCH}: {'enough' if per_day * EPOCH_DAYS <= BATCH else 'NOT enough'})"
    )
    gaps = [(b - a).total_seconds() for a, b in zip(conns, conns[1:])]
    if gaps:
        print(
            f"  between connections: median {fmt_s(median(gaps))}, p10 {fmt_s(pct(gaps, 10))}, "
            f"p90 {fmt_s(pct(gaps, 90))}, min {fmt_s(min(gaps))}"
        )
        burst = max(sum(1 for c in conns if t <= c < t + timedelta(seconds=60)) for t in conns)
        print(f"  most connections within one minute: {burst}")
    by_hour = defaultdict(int)
    for t in conns:
        by_hour[t.strftime("%Y-%m-%d %H:00")] += 1
    busiest = sorted(by_hour.items(), key=lambda kv: -kv[1])[:5]
    print("  busiest hours (UTC): " + ", ".join(f"{h[11:16]}×{n}" for h, n in busiest))
    if nets:
        follow = []
        for n in nets:
            nxt = next((c for c in conns if c >= n), None)
            if nxt is not None and (nxt - n).total_seconds() < 600:
                follow.append((nxt - n).total_seconds())
        print(f"  network changes: {len(nets)}; followed by a new relay connection within 10 min: {len(follow)}")
        if follow:
            print(
                f"    delay to that connection: median {fmt_s(median(follow))}, "
                f"max {fmt_s(max(follow))} — the window a relay links the old and new IP in"
            )
    for k, why in (
        ("fallback", "rustls fallback used — its connections are NOT counted above"),
        ("dial_failed", "per-connection dials failed"),
        ("mode_off", "VEIL was off at some point"),
    ):
        if kinds[k]:
            print(f"  ! {k}: {kinds[k]} — {why}")
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    data = read(sys.argv[1:])
    found = False
    for label in sorted(data):
        found |= report(label, data[label])
    sys.exit(0 if found else 1)


if __name__ == "__main__":
    main()
