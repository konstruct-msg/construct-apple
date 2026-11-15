#!/usr/bin/env bash
# T2 of todo 309: block the service's transports one after another and let the stand watch what
# the app falls back to. Run by the owner, as root, once:
#
#   sudo scripts/pcap_stand/pf_block.sh <service address or host> […]
#
# Prefer the addresses the app actually connected to (stand.sh prints them from the last capture):
# the resolver root sees is not always the one the simulator uses. On 2026-11-15 root's lookup
# returned fake-IP answers (198.18.0.0/15, a proxy's range) while the app connected to the real
# address, and three phases blocked nothing. A host name is still accepted, and a fake-IP answer
# stops the script.
#
# Phases, PHASE_SECONDS each (default 90): udp443 → tcp443 → both → off. The current phase is
# written to logs/pcap_stand/pf_phase, which stand.sh's driver reads to relaunch the app at each
# change. Only traffic to the service hosts' addresses is blocked, nothing else on the Mac.
# The rules live in their own anchor under com.apple/ (the system pf.conf already loads
# com.apple/*), and are flushed on exit, Ctrl-C included.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "pf_block: run with sudo" >&2; exit 77; }
[[ $# -gt 0 ]] || { echo "usage: sudo $0 <service host> …" >&2; exit 64; }

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$HERE/../.." && pwd)/logs/pcap_stand"
PHASE_FILE="$OUT/pf_phase"
ANCHOR="com.apple/pcap_stand"
SECS="${PHASE_SECONDS:-90}"
mkdir -p "$OUT"

ips=()
for h in "$@"; do
  if [[ "$h" =~ ^[0-9.]+$ || "$h" == *:* ]]; then ips+=("$h"); continue; fi
  while read -r ip; do [[ -n "$ip" ]] && ips+=("$ip"); done < <(dscacheutil -q host -a name "$h" | awk '/ip_address|ipv6_address/{print $2}')
done
[[ ${#ips[@]} -gt 0 ]] || { echo "pf_block: no address for $*" >&2; exit 1; }
for ip in "${ips[@]}"; do
  if [[ "$ip" =~ ^198\.1[89]\. ]]; then
    echo "pf_block: $ip is a fake-IP answer (198.18.0.0/15) — pass the address the app connects to" >&2
    exit 1
  fi
done
table="{ $(printf '%s ' "${ips[@]}" | sort -u | tr '\n' ' ') }"

token="$(pfctl -E 2>&1 | awk '/Token/{print $3}')"
cleanup() {
  pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  [[ -n "$token" ]] && pfctl -X "$token" >/dev/null 2>&1 || true
  echo off >"$PHASE_FILE"
  echo "pf_block: rules flushed"
}
trap cleanup EXIT

phase() {
  local name="$1" rules="$2"
  if [[ -n "$rules" ]]; then
    printf '%s\n' "$rules" | pfctl -a "$ANCHOR" -f - 2>/dev/null
  else
    pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
  fi
  echo "$name" >"$PHASE_FILE"
  echo "pf_block: $(date +%H:%M:%S) phase $name"
  pfctl -a "$ANCHOR" -s rules 2>/dev/null | sed 's/^/    /'
  sleep "$SECS"
}

phase udp443 "block drop out quick proto udp from any to $table port 443"
phase tcp443 "block drop out quick proto tcp from any to $table port 443"
phase both   "block drop out quick proto { tcp udp } from any to $table port 443"
