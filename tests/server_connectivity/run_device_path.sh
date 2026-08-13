#!/usr/bin/env bash
# Device-path diagnosis for Construct (VEIL off / direct path).
#
# Run this on a Mac/Linux host that uses the **same network path as the phone**
# (recommended: iPhone Personal Hotspot → Mac). Pair with packet capture.
#
# Usage:
#   ./run_device_path.sh                  # soak 60s + storm
#   ./run_device_path.sh --hold 90
#   ./run_device_path.sh --with-csc        # also run csc diagnose (needs cargo build)
#   ./run_device_path.sh --capture         # print csc capture command (run as root separately)
#   ACCESS_TOKEN=… USER_ID=… DEVICE_ID=… ./run_device_path.sh   # full MessageStream soak
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSC_DIR="${CSC_DIR:-$HOME/Code/construct-security-cli}"
HOLD=60
WITH_CSC=0
CAPTURE_HINT=0
STORM=1
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hold) HOLD="$2"; shift 2 ;;
    --with-csc) WITH_CSC=1; shift ;;
    --capture) CAPTURE_HINT=1; shift ;;
    --no-storm) STORM=0; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

echo "════════════════════════════════════════════════════════"
echo " Construct device-path test"
echo " Hold/soak: ${HOLD}s"
echo " Network: use phone hotspot if diagnosing RU path"
echo "════════════════════════════════════════════════════════"
echo

if [[ "$CAPTURE_HINT" -eq 1 ]]; then
  echo "In another terminal (root):"
  echo "  cd \"$CSC_DIR\" && cargo build --release"
  echo "  sudo ./target/release/csc capture --construct -i en0 --duration $((HOLD + 30)) --analyze --save-pcap ~/Desktop/construct-path.pcap"
  echo "  # pick -i from: networksetup -listallhardwareports"
  echo
fi

if [[ "$WITH_CSC" -eq 1 ]]; then
  if [[ -x "$CSC_DIR/target/release/csc" ]]; then
    CSC="$CSC_DIR/target/release/csc"
  elif command -v csc >/dev/null 2>&1; then
    CSC="$(command -v csc)"
  else
    echo "Building csc…"
    (cd "$CSC_DIR" && cargo build --release)
    CSC="$CSC_DIR/target/release/csc"
  fi
  echo "── csc diagnose --construct ──"
  "$CSC" diagnose --construct --hold-secs "$HOLD" --pcap-hint --json "/tmp/construct-diagnose.json" || true
  echo "JSON: /tmp/construct-diagnose.json"
  echo
fi

SOAK_ARGS=(--duration "$HOLD" --json "/tmp/construct-bidi-soak.json")
if [[ "$STORM" -eq 1 ]]; then
  SOAK_ARGS+=(--storm)
fi
SOAK_ARGS+=("${EXTRA[@]+"${EXTRA[@]}"}")

echo "── test_bidi_soak.py ──"
if ! python3 -c "import grpc" 2>/dev/null; then
  echo "Installing grpcio…"
  pip3 install --user grpcio
fi
python3 "$SCRIPT_DIR/test_bidi_soak.py" "${SOAK_ARGS[@]}"
echo
echo "Reports:"
echo "  /tmp/construct-bidi-soak.json"
[[ -f /tmp/construct-diagnose.json ]] && echo "  /tmp/construct-diagnose.json"
echo
echo "Done. Share both JSON files + optional pcap for analysis."
