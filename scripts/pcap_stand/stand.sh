#!/usr/bin/env bash
# The app under capture on one stand simulator (todos 309, 310).
#
#   stand.sh start <name>     # boot role A, start the capture, launch the app
#   …drive the scenario (two_sims.sh / axe): open, send, background, foreground, relaunch…
#   stand.sh stop  <name>     # stop the capture, collect the needles, run t1, t2, t3
#                               (STAND_TEXT=<username typed in the run> adds it to the needles)
#   stand.sh follow-pf        # T2: while the owner runs `sudo pf_block.sh <hosts>`, relaunch the
#                               app at each phase it writes, until the phase is "off"
#
# A green run's capture is deleted (it holds the whole Mac's traffic: a gigabyte in five minutes);
# KEEP_PCAP=1 keeps it. A red run's capture is always kept.
#
# Run control.sh first, in the same boot: a green here means something only next to a red there.
# The build installed is whatever two_sims.sh built (CONFIGURATION=Beta for what testers run).
# Service hosts come from that build's Info.plist (GRPC_HOST, QUIC_GATEWAY_HOST when present);
# its registrable domain picks up every other service name the capture's DNS answers mention.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/logs/pcap_stand"
STAND="${STAND_REPO:-$REPO}"     # the clone whose build two_sims.sh installs
BUNDLE_ID="${BUNDLE_ID:-maximeliseyev.constructmessenger}"

cmd="${1:-}"; name="${2:-}"
[[ -n "$cmd" && ( -n "$name" || "$cmd" == follow-pf ) ]] || { echo "usage: $0 start|stop <name> | follow-pf" >&2; exit 64; }

udid() { xcrun simctl list devices | awk -v n="${SIM_A_NAME:-Construct-A}" -F'[()]' '$1 ~ "^ *"n" *$" {print $2; exit}'; }
U="$(udid)"; [[ -n "$U" ]] || { echo "stand: no simulator ${SIM_A_NAME:-Construct-A}" >&2; exit 1; }

case "$cmd" in
  start)
    SIMS=a CONFIGURATION="${CONFIGURATION:-Beta}" "$STAND/scripts/two_sims.sh" up
    SIMS=a CONFIGURATION="${CONFIGURATION:-Beta}" "$STAND/scripts/two_sims.sh" install
    xcrun simctl terminate "$U" "$BUNDLE_ID" 2>/dev/null || true
    rm -f "$OUT/pf_phase"
    "$HERE/capture.sh" start "$name"
    xcrun simctl launch "$U" "$BUNDLE_ID" >/dev/null
    echo "stand: app launched on $U under capture $name"
    ;;
  stop)
    "$HERE/capture.sh" stop "$name"
    mkdir -p "$OUT/$name"
    texts=(); [[ -n "${STAND_TEXT:-}" ]] && texts=(--text "$STAND_TEXT")
    python3 -I "$HERE/needles.py" "$U" --bundle "$BUNDLE_ID" "${texts[@]}" -o "$OUT/$name/needles.json"
    app="$(xcrun simctl get_app_container "$U" "$BUNDLE_ID" app)"
    hosts=()
    for key in GRPC_HOST QUIC_GATEWAY_HOST; do
      h="$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Info.plist" 2>/dev/null || true)"
      [[ -n "$h" ]] && hosts+=(--host "$h")
    done
    [[ ${#hosts[@]} -gt 0 ]] || { echo "stand: the build names no service host" >&2; exit 1; }
    domain="$(echo "${hosts[1]}" | awk -F. '{print $(NF-1)"."$NF}')"
    pcap="$OUT/$name.pcap"
    red=0
    for t in t1 t2 t3; do
      if [[ $t == t1 ]]; then a=(--needles "$OUT/$name/needles.json"); else a=("${hosts[@]}" --domain "$domain"); fi
      python3 -I "$HERE/analyze.py" "$t" "$pcap" "${a[@]}" >"$OUT/$name/$t.txt" 2>&1 || red=1
      cat "$OUT/$name/$t.txt"
    done
    if [[ $red -eq 0 && "${KEEP_PCAP:-0}" != 1 ]]; then rm -f "$pcap"; echo "stand: green, capture deleted"; fi
    exit $red
    ;;
  follow-pf)
    last=""
    while :; do
      cur="$(cat "$OUT/pf_phase" 2>/dev/null || true)"
      if [[ -n "$cur" && "$cur" != "$last" ]]; then
        echo "stand: $(date +%H:%M:%S) phase $cur — relaunching the app"
        xcrun simctl terminate "$U" "$BUNDLE_ID" 2>/dev/null || true
        sleep 2
        xcrun simctl launch "$U" "$BUNDLE_ID" >/dev/null
        last="$cur"
        [[ "$cur" == off ]] && { sleep 20; break; }
        # Half-way through a phase: to the background and back, the reconnect path.
        sleep 35
        xcrun simctl launch "$U" com.apple.Preferences >/dev/null
        sleep 10
        xcrun simctl launch "$U" "$BUNDLE_ID" >/dev/null
      fi
      sleep 1
    done
    ;;
  *) echo "usage: $0 start|stop <name> | follow-pf" >&2; exit 64 ;;
esac
