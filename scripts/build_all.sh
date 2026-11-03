#!/bin/bash
#
# build_all.sh — build the iOS app and Construct Desktop, the two targets a shared change can break.
#
# CI cannot build either (no xcframeworks on a runner), and ConstructMessenger/ is compiled into
# both. A change that built for iOS has twice left Desktop red for days because nobody built it.
# This is the one command for "does it still compile, everywhere": run it before a PR that touches
# ConstructMessenger/.
#
# Before building, it checks that every slice the xcframeworks' Info.plist names is on disk. The
# Info.plist files are in git and the .a files are not, so a fresh clone or a worktree has
# frameworks that look complete and link nothing — or a missing macOS slice when the libraries
# were built without --all.
#
# Usage:
#   scripts/build_all.sh                         both targets
#   scripts/build_all.sh --ios | --desktop       one
#   scripts/build_all.sh --frameworks-from DIR   first fill missing slices from another clone
#                                                (APFS clone copy, no extra disk), e.g. a worktree
#                                                from the main checkout
#   scripts/build_all.sh --configuration Beta    build a configuration other than the scheme's
#                                                (Debug). Beta compiles without DEBUG since
#                                                2026-11-03, so code that reaches a DEBUG-only
#                                                seam builds in Debug and fails only here
#
# Prints one line per target, `BUILD <target>: OK|FAILED`, and exits non-zero if any failed. Logs
# are kept in $TMPDIR/construct-build-all/.
# Signing is off: this checks compilation and linking, not a shippable product.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
LOG_DIR="${TMPDIR:-/tmp}/construct-build-all"
mkdir -p "$LOG_DIR"

DO_IOS=1; DO_DESKTOP=1; FROM=""; CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ios) DO_DESKTOP=0 ;;
    --desktop) DO_IOS=0 ;;
    --frameworks-from) FROM="${2:?--frameworks-from needs a directory}"; shift ;;
    --configuration) CONFIG="${2:?--configuration needs a name}"; shift ;;
    *) echo "usage: $0 [--ios|--desktop] [--frameworks-from DIR] [--configuration NAME]" >&2; exit 2 ;;
  esac
  shift
done

# ── frameworks: every slice Info.plist names must exist ───────────────────────────────────────
missing=()
for fw in ConstructCore.xcframework ConstructTransport.xcframework; do
  [ -f "$fw/Info.plist" ] || { echo "✗ $fw/Info.plist missing"; exit 1; }
  while IFS= read -r slice; do
    [ -z "$slice" ] && continue
    if [ ! -s "$fw/$slice" ] && [ -n "$FROM" ] && [ -s "$FROM/$fw/$slice" ]; then
      mkdir -p "$(dirname "$fw/$slice")"
      cp -c "$FROM/$fw/$slice" "$fw/$slice" && echo "  filled $fw/$slice from $FROM"
    fi
    [ -s "$fw/$slice" ] || missing+=("$fw/$slice")
  done < <(python3 -I -c '
import plistlib, sys
for lib in plistlib.load(open(sys.argv[1], "rb"))["AvailableLibraries"]:
    print(lib["LibraryIdentifier"] + "/" + lib["LibraryPath"])
' "$fw/Info.plist")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "✗ xcframework slices missing (Info.plist names them, the disk does not have them):"
  printf '    %s\n' "${missing[@]}"
  echo "  Build them: ./build_crypto_lib.sh --all && ./build_transport_lib.sh --all"
  echo "  or, in a worktree: $0 --frameworks-from <main clone>"
  exit 3
fi

# ── build ─────────────────────────────────────────────────────────────────────────────────────
STATUS=0
build() {  # name scheme destination
  local name="$1${CONFIG:+-$CONFIG}" scheme="$2" dest="$3"
  local log="$LOG_DIR/$name.log"
  echo "── building $name ($scheme) → $log"
  xcodebuild build -project ConstructMessenger.xcodeproj -scheme "$scheme" -destination "$dest" \
    ${CONFIG:+-configuration "$CONFIG"} CODE_SIGNING_ALLOWED=NO > "$log" 2>&1
  local rc=$?
  # The exit code alone has lied before; the result line is the proof.
  if [ $rc -eq 0 ] && grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"; then
    echo "BUILD $name: OK"
  else
    echo "BUILD $name: FAILED (xcodebuild exit $rc)"
    grep -E '^.+:[0-9]+:[0-9]+: error:|^error:' "$log" | sort -u | head -20 | sed 's/^/    /'
    STATUS=1
  fi
}

[ $DO_IOS = 1 ] && build ios ConstructMessenger 'generic/platform=iOS Simulator'
[ $DO_DESKTOP = 1 ] && build desktop 'Construct Desktop' 'platform=macOS'
exit $STATUS
