#!/usr/bin/env python3
"""
squash_logs — Compress Construct Messenger logs for LLM consumption.

Input:  raw logs (file, stdin, or macOS clipboard)
Output: deduplicated, timestamp-compressed, emoji-stripped log lines.

Usage:
    ./squash_logs < file.log          # from file
    ./squash_logs file.log            # from file
    cat file.log | ./squash_logs      # from stdin
    ./squash_logs --clip              # from macOS clipboard
    ./squash_logs --clip --copy       # from clipboard, copy result back

Compression rules:
    1. Strip emoji to compact markers (* + - ! @ ~)
    2. Relative timestamps (+0.0s, +5.3s) instead of absolute
    3. Deduplicate consecutive identical lines (xN suffix)
    4. Truncate field values > 80 chars
    5. Drop framework stack frames from crash logs
    6. Bucket heartbeat/ping lines (1 per 30s window)
"""

import re
import sys
from datetime import datetime

# -- Emoji -> compact markers --------------------------------------------------
EMOJI_MAP = {
    '\U0001f9ca': '*',  # ice cube
    '\u2705': '+',      # check
    '\u274c': '-',      # cross
    '\u26a0\ufe0f': '!',  # warning
    '\U0001f534': '!',  # red circle
    '\U0001f7e2': '+',  # green circle
    '\U0001f7e1': '~',  # yellow circle
    '\U0001f4e1': '@',  # satellite antenna
    '\U0001f4e9': '@',  # envelope
    '\U0001f4e4': '@',  # outbox
    '\U0001f4e5': '@',  # inbox
    '\U0001f4e8': '@',  # incoming envelope
    '\U0001f50c': '~',  # electric plug
    '\U0001f511': '~',  # key
    '\U0001f510': '~',  # closed lock
    '\U0001f504': '~',  # arrows counterclockwise
    '\U0001f6d1': '-',  # stop sign
    '\u23f0': '~',      # alarm clock
    '\U0001f4f1': '~',  # mobile phone
    '\U0001f4d6': '~',  # book
    '\U0001f4ec': '@',  # mailbox
    '\U0001f4cb': '~',  # clipboard
    '\U0001f501': '~',  # clockwise arrows
    '\U0001f3c1': '~',  # racing flag
    '\U0001f4ac': '@',  # speech balloon
    '\U0001f4dd': '~',  # memo
    '\U0001f4e6': '~',  # package
}

def strip_emoji(line: str) -> str:
    for emoji, marker in EMOJI_MAP.items():
        line = line.replace(emoji, marker)
    # Catch any remaining emoji (main Unicode ranges)
    line = re.sub(r'[\U0001F300-\U0001F9FF\u2600-\u27BF\u2B50]', '', line)
    return line

# -- Timestamp compression -----------------------------------------------------
TS_RE = re.compile(r'(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)')
FIRST_TS = None

def compress_ts(line: str) -> str:
    global FIRST_TS
    # Only parse timestamps from actual log lines ([YYYY-MM-DD prefix)
    if not line.startswith('['):
        return line
    m = TS_RE.search(line)
    if not m:
        return line
    ts_str = m.group(1).replace('T', ' ').replace('Z', '')
    try:
        ts = datetime.strptime(ts_str, '%Y-%m-%d %H:%M:%S.%f')
    except ValueError:
        try:
            ts = datetime.strptime(ts_str, '%Y-%m-%d %H:%M:%S')
        except ValueError:
            return line
    if FIRST_TS is None:
        FIRST_TS = ts
        delta = 0.0
    else:
        delta = (ts - FIRST_TS).total_seconds()
    return TS_RE.sub('+{:.1f}s'.format(delta), line, count=1).replace('Z]', ']')

# -- Bucket patterns (lines matching these get collapsed) ----------------------
BUCKET_PATTERNS = [
    ('heartbeat', 30.0),
    ('keepalive', 30.0),
    ('sendHeartbeat', 30.0),
    ('reconnecting', 10.0),
]

# -- Truncate long field values ------------------------------------------------
def truncate_fields(line: str) -> str:
    return re.sub(r'=([A-Za-z0-9+/=_-]{80,})', r'=...', line)

# -- Drop noise lines ----------------------------------------------------------
NOISE_PATTERNS = [
    r'^\s*$',
    r'^\s*at\s+\S+\(.*\)',
    r'^\s*\.\.\.\s*\d+\s*more',
    r'Caused by:',
    r'^\s*\d+\s*frames?\s*omitted',
    r'NSManagedObjectContext.*DidSave',
    r'ObservationRegistrar',
]

# Xcode/system noise — lines that carry no diagnostic value for app bugs
SYSTEM_NOISE = [
    'nw_socket', 'nw_endpoint', 'nw_protocol', 'nw_read_request',
    'nw_connection', 'tcp_input', 'tcp_output',
    'quic_conn_keepalive',
    'RTIInputSystem', 'Snapshotting a view',
    'The variant selector cell',
    '<OnScrollGeometryChange', 'Update NavigationRequestObserver',
    'Gesture: System gesture gate timed out',
    'Message from debugger',
    'Reading from public effective user settings',
    'Can.t get TCP_INFO', 'Can.t get TCP_CONNECTION_INFO',
    'setsockopt SO_CONNECTION_IDLE',
    'Not calling remove_input_handler',
]

def is_noise(line: str) -> bool:
    # Skip header/metadata lines
    if line.startswith('==') or line.startswith('App ') or line.startswith('Build') or line.startswith('Device') or line.startswith('iOS ') or line.startswith('Identifier') or line.startswith('Started') or line.startswith('Exported'):
        return True
    # Skip Xcode/system noise lines
    for pattern in SYSTEM_NOISE:
        if pattern in line:
            return True
    # Debug-only categories that are rarely useful in LLM context
    if '[EnergyMonitor]' in line or '[BackgroundFetch]' in line or '[DeepLink]' in line:
        return True
    return any(re.search(p, line) for p in NOISE_PATTERNS)

# -- Main processing -----------------------------------------------------------
def process(lines):
    global FIRST_TS
    FIRST_TS = None
    out_lines = []
    prev = None
    prev_bucket = None
    bucket_count = 0
    repeat_count = 0

    def flush_repeats():
        nonlocal repeat_count
        if repeat_count:
            out_lines.append('  (repeated x{})'.format(repeat_count))
            repeat_count = 0

    def flush_bucket():
        nonlocal prev_bucket, bucket_count
        if prev_bucket and bucket_count:
            out_lines.append('  ({} x{})'.format(prev_bucket, bucket_count))
            prev_bucket = None
            bucket_count = 0

    for raw in lines:
        raw = raw.rstrip('\n\r')
        if not raw or is_noise(raw):
            continue

        line = strip_emoji(raw)
        line = compress_ts(line)
        line = truncate_fields(line)
        line = re.sub(r'\s+', ' ', line).strip()

        if not line:
            continue

        # Dedup consecutive identical lines
        if line == prev:
            repeat_count += 1
            continue
        flush_repeats()

        # Bucket heartbeat-style lines
        matched = False
        for pattern, _ in BUCKET_PATTERNS:
            if pattern in line.lower():
                if prev_bucket == pattern:
                    bucket_count += 1
                    matched = True
                    break
                else:
                    flush_bucket()
                    prev_bucket = pattern
                    bucket_count = 1
                    matched = True
                    break
        if matched:
            prev = None
            continue

        flush_bucket()
        out_lines.append(line)
        prev = line

    flush_repeats()
    flush_bucket()
    return '\n'.join(out_lines)

# -- Entry point ---------------------------------------------------------------
if __name__ == '__main__':
    if '--help' in sys.argv or '-h' in sys.argv:
        print(__doc__)
        sys.exit(0)

    if '--clip' in sys.argv:
        import subprocess
        raw = subprocess.check_output(['pbpaste']).decode('utf-8', errors='replace')
        result = process(raw.split('\n'))
        if '--copy' in sys.argv:
            subprocess.run(['pbcopy'], input=result.encode('utf-8'))
            print('Copied {} bytes to clipboard'.format(len(result)), file=sys.stderr)
        else:
            print(result)
    elif len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            print(process(f.readlines()))
    else:
        print(process(sys.stdin.readlines()))
