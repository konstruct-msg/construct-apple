#!/usr/bin/env bash
# Start and stop a host capture for the pcap stand (todos 309, 310).
#
#   capture.sh start <name>   # tcpdump on the default-route interface → logs/pcap_stand/<name>.pcap
#   capture.sh stop  <name>
#
# Simulators share the host's network stack, so the app's packets are on the host's default
# interface. pktap would name each packet's process, but creating the pktap interface needs root
# even with bpf access, so the analyzer picks flows by service address instead.
# /dev/bpf* belongs to root after every boot; once
# per boot the owner runs
#   sudo chgrp access_bpf /dev/bpf* && sudo chmod g+rw /dev/bpf*
# (the account is in access_bpf), and the capture then runs without sudo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/logs/pcap_stand"
mkdir -p "$OUT"

cmd="${1:-}"; name="${2:-}"
[[ -n "$cmd" && -n "$name" ]] || { echo "usage: $0 start|stop <name>" >&2; exit 64; }
pcap="$OUT/$name.pcap"; pidf="$OUT/$name.pid"

case "$cmd" in
  start)
    if [[ ! -r /dev/bpf0 || ! -w /dev/bpf0 ]]; then
      echo "capture: no access to /dev/bpf*; run: sudo chgrp access_bpf /dev/bpf* && sudo chmod g+rw /dev/bpf*" >&2
      exit 77
    fi
    [[ -e "$pcap" ]] && { echo "capture: $pcap exists; pick another name" >&2; exit 73; }
    iface="${IFACE:-$(route -n get default | awk '/interface:/{print $2}')}"
    tcpdump -i "$iface" -s 0 -w "$pcap" >"$OUT/$name.tcpdump.log" 2>&1 &
    echo $! >"$pidf"
    sleep 1
    kill -0 "$(cat "$pidf")" 2>/dev/null || { cat "$OUT/$name.tcpdump.log" >&2; exit 1; }
    echo "capture: $pcap on $iface (pid $(cat "$pidf"))"
    ;;
  stop)
    [[ -f "$pidf" ]] || { echo "capture: no running capture $name" >&2; exit 1; }
    pid="$(cat "$pidf")"
    kill -INT "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    rm -f "$pidf"
    tail -2 "$OUT/$name.tcpdump.log"
    ls -l "$pcap"
    ;;
  *) echo "usage: $0 start|stop <name>" >&2; exit 64 ;;
esac
