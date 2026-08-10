#!/bin/bash
#
# test_run.sh — run a scoped test target and turn a build stall into evidence.
#
# Mutation verification runs xcodebuild dozens of times a day. Six times between 2026-08-08 and
# 2026-08-10 a run wedged for the full 10-minute timeout and had to be killed, which cost two
# mutations their verification (they were reported as inconclusive rather than passed — a killed
# run and a surviving mutation look identical from the outside, and that is exactly the failure
# mode this repo has been bitten by before).
#
# What is established about those stalls:
#   · They are in the BUILD phase, not the simulator. The last line printed was
#     `builtin-swiftStdLibTool` (CopySwiftLibs) twice and `builtin-validationUtility` (Validate)
#     twice — both immediately after a `codesign` step, both near the end of the build.
#   · They never reached test execution: zero "Clone …" lines in any of the four captured logs.
#     Parallel test cloning is therefore NOT the cause.
#   · A healthy scoped run is 45–75s. A stall is 600s+. There is no ambiguous middle.
#
# What is not established: the cause. Seven consecutive runs after the fact were clean, so it
# could not be reproduced on demand. Rather than guess, this script captures the state of the
# machine the next time it happens — process list plus a `sample` of the build service — so the
# next attempt starts from data.
#
# Usage:
#   scripts/test_run.sh                                  # whole test target
#   scripts/test_run.sh ConstructMessengerTests/FooTests # one class, for mutation runs
#
# Env: STALL_SECONDS (default 180), DEVICE (default "iPhone 17").

set -uo pipefail

ONLY="${1:-}"
STALL_SECONDS="${STALL_SECONDS:-180}"
DEVICE="${DEVICE:-iPhone 17}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/construct-test-run"
mkdir -p "$OUT"
LOG="$OUT/xcodebuild.log"
DIAG="$OUT/stall-diagnosis-$(date +%Y%m%d-%H%M%S).txt"

ARGS=(-project "$ROOT/ConstructMessenger.xcodeproj" -scheme ConstructMessenger
      -destination "platform=iOS Simulator,name=$DEVICE"
      # No clones: the base simulator is reused. Not a fix for the stall (which happens before
      # any clone exists) — it just removes a minute of boot from every mutation run.
      -parallel-testing-enabled NO)
[ -n "$ONLY" ] && ARGS+=(-only-testing:"$ONLY")

echo "→ xcodebuild ${ONLY:-<all tests>} (stall watchdog at ${STALL_SECONDS}s)"
START=$(date +%s)
xcodebuild "${ARGS[@]}" test > "$LOG" 2>&1 &
BUILD_PID=$!

capture() {
    {
        echo "STALL after $(( $(date +%s) - START ))s — ${ONLY:-<all tests>}"
        echo
        echo "== last 3 log lines (the command that did not return)"
        tail -3 "$LOG"
        echo
        echo "== disk"
        df -h /System/Volumes/Data | tail -1
        echo
        echo "== build/sign/simulator processes"
        ps -Ao pid,pcpu,etime,command | grep -Ei "xcodebuild|XCBBuildService|swift-stdlib|codesign|bitcode_strip|CoreSimulator|syspolicyd|mds" | grep -v grep
        echo
        for p in $(pgrep -f "XCBBuildService|codesign|swift-stdlib-tool" | head -3); do
            echo "== sample $p"
            sample "$p" 3 -mayDie 2>/dev/null | sed -n '/Call graph/,/Binary Images/p' | head -60
        done
    } > "$DIAG" 2>&1
    echo "✗ stalled — diagnosis: $DIAG"
}

while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 10
    if [ $(( $(date +%s) - START )) -gt "$STALL_SECONDS" ]; then
        capture
        kill "$BUILD_PID" 2>/dev/null; sleep 2; kill -9 "$BUILD_PID" 2>/dev/null
        exit 2
    fi
done
wait "$BUILD_PID"; STATUS=$?

# A build failure looks exactly like "no test failed" if you only grep for failures, which has
# nearly cost this repo a correct test before. Report the build verdict separately.
if ! grep -qE "\*\* TEST (SUCCEEDED|FAILED)" "$LOG"; then
    echo "✗ build did not complete — NOT a passing mutation. Log: $LOG"
    grep -E "error: " "$LOG" | head -5
    exit 3
fi

# Two output formats, and they are not interchangeable. Parallel runs print
#   Test case 'FooTests.testBar()' passed
# while a non-parallel run prints
#   Test Case '-[ConstructMessengerTests.FooTests testBar]' passed
# The counting command in AGENTS.md matches only the first, so it reports 0 against a run that
# passed everything — the same shape of lie as a build failure reading like "nothing failed".
PASSED=$(grep -oiE "^Test case '[^']+' passed" "$LOG" | sort -u | wc -l | tr -d ' ')
echo "$(grep -oE '\*\* TEST (SUCCEEDED|FAILED)' "$LOG" | tail -1) — $PASSED unique passed, $(( $(date +%s) - START ))s"
grep -oiE "Test case '[^']+' failed" "$LOG" | sort -u
exit $STATUS
