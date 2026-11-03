#!/bin/bash
#
# check_all.sh — every textual check, in one place, run the same way locally and on CI.
#
# CI used to list each check as its own job, and the local habit was to remember which ones to run.
# Two lists of one thing drift: a check added to one is missing from the other, and a red CI then
# shows what the author never saw. So the list lives here, the pre-push hook runs it
# (scripts/install_hooks.sh), and .github/workflows/checks.yml calls this script and nothing else.
# CI stays as the backstop for a push that skipped the hook (--no-verify, another machine, an agent).
#
# A new scripts/check_* file that is not in CHECKS below fails this script: a check nothing runs
# is a check that does not exist.
#
# Usage:
#   scripts/check_all.sh              run every check
#   scripts/check_all.sh --only NAME  run one (CI runs privacy-manifest on macOS this way)
#   scripts/check_all.sh --list       print the check names
#
# A check that needs a tool this machine lacks (plutil off macOS) is reported SKIP, by name, and
# never counted as a pass; with --only, a skip fails.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# name | needs (a command that must exist, or -) | command
CHECKS=(
  "localization|-|./scripts/check_localization.sh"
  "ui-tokens|-|./scripts/check_ui_tokens.sh"
  "appstore-metadata|-|./scripts/check_appstore_metadata.sh"
  "build-versions|-|./scripts/check_build_versions.sh"
  "forks|python3|python3 -I scripts/check_forks.py self-test && python3 -I scripts/check_forks.py pins"
  "agents-md|-|./scripts/check_agents_md.sh"
  "desktop-sources|python3|python3 -I scripts/check_desktop_sources.py self-test && python3 -I scripts/check_desktop_sources.py"
  "build-conditions|python3|python3 -I scripts/check_build_conditions.py"
  "privacy-manifest|plutil|./scripts/check_privacy_manifest.sh"
)

ONLY=""
case "${1:-}" in
  --only) ONLY="${2:?--only needs a check name}" ;;
  --list) for c in "${CHECKS[@]}"; do echo "${c%%|*}"; done; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--only NAME | --list]" >&2; exit 2 ;;
esac

FAILED=()
SKIPPED=()
PASSED=0

# Every check script must be listed. Matched on the script's file name inside the command.
if [ -z "$ONLY" ]; then
  for f in scripts/check_*; do
    base="$(basename "$f")"
    [ "$base" = "check_all.sh" ] && continue
    listed=0
    for c in "${CHECKS[@]}"; do
      case "$c" in *"$base"*) listed=1 ;; esac
    done
    if [ "$listed" = 0 ]; then
      echo "✗ $f is not in check_all.sh CHECKS — add it, or nothing runs it"
      FAILED+=("unlisted:$base")
    fi
  done
fi

found=0
for c in "${CHECKS[@]}"; do
  name="${c%%|*}"; rest="${c#*|}"; needs="${rest%%|*}"; cmd="${rest#*|}"
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  found=1
  if [ "$needs" != "-" ] && ! command -v "$needs" >/dev/null 2>&1; then
    echo "── $name: SKIP (no $needs on this machine)"
    SKIPPED+=("$name")
    continue
  fi
  echo "── $name"
  if bash -c "$cmd"; then
    PASSED=$((PASSED + 1))
  else
    FAILED+=("$name")
  fi
done

if [ -n "$ONLY" ] && [ "$found" = 0 ]; then
  echo "✗ no check named '$ONLY' (see --list)" >&2
  exit 2
fi

echo
echo "checks: $PASSED passed, ${#FAILED[@]} failed, ${#SKIPPED[@]} skipped"
[ ${#SKIPPED[@]} -gt 0 ] && echo "  skipped: ${SKIPPED[*]}"
# Asked for by name and not run is not a pass: CI's macOS job must not go green on a runner without plutil.
if [ -n "$ONLY" ] && [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "✗ $ONLY was asked for and skipped"
  exit 1
fi
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "  failed:  ${FAILED[*]}"
  exit 1
fi
exit 0
