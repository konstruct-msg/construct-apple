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
# SOLVED 2026-08-11, by this script's own capture. It was never the build:
#
#     Executed 7 tests, with 7 failures (0 unexpected) in 0.189 (0.191) seconds
#     Test Suite 'Selected tests' failed at 2026-08-11 10:52:51.634.
#     … then 191 seconds of nothing.
#
# xcodebuild finishes the test run and then does not exit. Every stall happened on a run where
# tests FAILED — which is every mutation run, which is why three days of evidence pointed at the
# build phase: the last *printed* line was a build command, because printing is buffered and
# nothing was printed after the verdict. The earlier reading below was wrong on the location and
# wrong on ruling out test execution; it is kept because the reasoning from it (a stall is 600s+
# against a 45-75s healthy run) is what made the capture worth writing.
#
# So the loop now waits for the verdict line, not for the process. That was half of it. The
# other half, found 2026-11-03 in this script's capture (`simctl diagnose` alive 2:18 into a
# stall): on a failure xcodebuild collects a simulator sysdiagnose *before* printing the verdict,
# with a 600s timeout. `-collect-test-diagnostics never` below turns that off. The stall capture
# stays for whatever comes next.
#
# Usage:
#   scripts/test_run.sh                                  # whole test target
#   scripts/test_run.sh ConstructMessengerTests/FooTests # one class, for mutation runs
#   scripts/test_run.sh ConstructMessengerTests/FooTests ConstructMessengerTests/BarTests/testBaz
#
# Env: STALL_SECONDS (default 180), DEVICE (default: Construct-Test, else the first iPhone).
#
# The last line is always `VERDICT: …`, and the exit code is derived from it — never from
# xcodebuild's, which this script kills once the result line appears (so `wait` reports 143 for a
# green run):
#   0  PASS      every test passed, and every id asked for ran at least one test
#   1  FAIL      a test failed, or the run said TEST FAILED
#   2  STALL     no result line within STALL_SECONDS; diagnosis written
#   3  NO-BUILD  the build did not complete — NOT a passing mutation
#   4  NO-TESTS  zero tests ran, or an id ran none — a misspelt class runs 0 tests and xcodebuild
#                calls that TEST SUCCEEDED; a battery reads it as "nothing went red"
#   5  USAGE     an argument with whitespace: a list that reached the script as one word (zsh
#                does not split "$TESTS") would run 0 tests

set -uo pipefail

FROM_LOG=""
if [ "${1:-}" = "--from-log" ]; then
    # Judge an existing log without running anything — how the verdict logic itself is tested.
    FROM_LOG="${2:?--from-log needs a file}"; shift 2
fi
IDS=("$@")
for id in ${IDS[@]+"${IDS[@]}"}; do
    if [[ "$id" =~ [[:space:]] ]]; then
        echo "✗ test id contains whitespace: '$id' — pass ids as separate arguments"
        echo "VERDICT: USAGE"
        exit 5
    fi
done
ONLY="${IDS[*]-}"
STALL_SECONDS="${STALL_SECONDS:-180}"
# The device is checked before anything builds: "iPhone 17" was the hardcoded default and this Mac
# has no simulator by that name, so every run came back NO-BUILD after a full timeout's wait.
# Resolution: $DEVICE, else a simulator named Construct-Test, else the first available iPhone.
WANT_DEVICE="${DEVICE:-}"
if [ -z "$FROM_LOG" ]; then
DEVICE="$(DEVICE="$WANT_DEVICE" python3 -I -c '
import json, os, subprocess, sys
want = os.environ.get("DEVICE", "")
data = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                                 capture_output=True, text=True).stdout or "{}")
names = [d["name"] for rt, ds in sorted(data.get("devices", {}).items()) if "iOS" in rt for d in ds]
pick = (want if want in names else None) if want else (
    "Construct-Test" if "Construct-Test" in names else next((n for n in names if n.startswith("iPhone")), None))
if not pick:
    sys.stderr.write("available iOS simulators: " + (", ".join(names) or "none") + "\n")
    sys.exit(1)
print(pick)
')" || { echo "✗ no simulator ${WANT_DEVICE:+named '$WANT_DEVICE' }to run on (see xcrun simctl list devices available)"; echo "VERDICT: NO-BUILD"; exit 3; }
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/construct-test-run"
mkdir -p "$OUT"
LOG="$OUT/xcodebuild.log"
DIAG="$OUT/stall-diagnosis-$(date +%Y%m%d-%H%M%S).txt"

run_tests() {
    ARGS=(-project "$ROOT/ConstructMessenger.xcodeproj" -scheme ConstructMessenger
          -destination "platform=iOS Simulator,name=$DEVICE"
          # No clones: the base simulator is reused. Not a fix for the stall (which happens before
          # any clone exists) — it just removes a minute of boot from every mutation run.
          -parallel-testing-enabled NO
          # The stall itself (2026-11-03): on a failing test xcodebuild runs `simctl diagnose
          # --timeout=600` — a sysdiagnose of the simulator — *before* it prints the result line.
          # A mutation run fails by design, so the watchdog fired on it whenever that took >180s.
          -collect-test-diagnostics never)
    for id in ${IDS[@]+"${IDS[@]}"}; do ARGS+=(-only-testing:"$id"); done

    echo "→ xcodebuild ${ONLY:-<all tests>} on $DEVICE (stall watchdog at ${STALL_SECONDS}s)"
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
        sleep 5
        # xcodebuild can finish the tests and then fail to exit. Captured 2026-08-11: "Executed 7
        # tests ... in 0.189 seconds" followed by 191s of nothing, on a run where tests FAILED — which
        # is every mutation run, which is why this looked like a build stall for three days. The
        # verdict line is the real completion signal; the process exiting is not.
        if grep -qE "\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG" 2>/dev/null; then
            sleep 2
            kill "$BUILD_PID" 2>/dev/null
            break
        fi
        if [ $(( $(date +%s) - START )) -gt "$STALL_SECONDS" ]; then
            capture
            kill "$BUILD_PID" 2>/dev/null; sleep 2; kill -9 "$BUILD_PID" 2>/dev/null
            echo "VERDICT: STALL"
            exit 2
        fi
    done
    # xcodebuild's own status is not used: it was killed after the result line.
    wait "$BUILD_PID" 2>/dev/null
}

START=$(date +%s)
if [ -n "$FROM_LOG" ]; then
    LOG="$FROM_LOG"
else
    run_tests
fi
ELAPSED=$(( $(date +%s) - START ))

# A build failure looks exactly like "no test failed" if you only grep for failures, which has
# nearly cost this repo a correct test before. Report the build verdict separately.
if ! grep -qE "\*\* TEST (SUCCEEDED|FAILED)" "$LOG"; then
    echo "✗ build did not complete — NOT a passing mutation. Log: $LOG"
    grep -E "error: " "$LOG" | head -5
    echo "VERDICT: NO-BUILD"
    exit 3
fi

# Two output formats, and they are not interchangeable. Parallel runs print
#   Test case 'FooTests.testBar()' passed
# while a non-parallel run prints
#   Test Case '-[ConstructMessengerTests.FooTests testBar]' passed
# so every match here is case-insensitive.
RESULTS="$(grep -oiE "^Test case '[^']+' (passed|failed)" "$LOG" | sort -u)"
PASSED=$(printf '%s\n' "$RESULTS" | grep -ciE "' passed$")
FAILED_LINES="$(printf '%s\n' "$RESULTS" | grep -iE "' failed$")"
FAILED=$(printf '%s\n' "$FAILED_LINES" | grep -ciE "' failed$")
RESULT_LINE="$(grep -oE '\*\* TEST (SUCCEEDED|FAILED)' "$LOG" | tail -1)"

echo "$RESULT_LINE — $PASSED unique passed, $FAILED failed, ${ELAPSED}s. Log: $LOG"
[ "$FAILED" -gt 0 ] && printf '%s\n' "$FAILED_LINES"

# Every id asked for must have run something. Class: '…FooTests testBar]' or 'FooTests.testBar()'.
EMPTY=()
for id in ${IDS[@]+"${IDS[@]}"}; do
    IFS=/ read -r _target cls method <<< "$id"
    [ -z "${cls:-}" ] && { EMPTY+=("$id (expected Target/Class[/method])"); continue; }
    if [ -n "${method:-}" ]; then pat="[.'\[]${cls}[ .]${method}[]( ]"; else pat="[.'\[]${cls}[ .]"; fi
    printf '%s\n' "$RESULTS" | grep -qE "$pat" || EMPTY+=("$id")
done

if [ "$FAILED" -gt 0 ] || [ "$RESULT_LINE" = "** TEST FAILED" ]; then
    # TEST FAILED with no failed case is a crash or a setup failure — still a FAIL, said so.
    [ "$FAILED" -eq 0 ] && echo "  (TEST FAILED with no failed test case — a crash or a bundle that did not load; read the log)"
    echo "VERDICT: FAIL $FAILED failed, $PASSED passed"
    exit 1
fi
if [ "$PASSED" -eq 0 ] || [ ${#EMPTY[@]} -gt 0 ]; then
    [ ${#EMPTY[@]} -gt 0 ] && printf '  ran no tests: %s\n' "${EMPTY[@]}"
    echo "VERDICT: NO-TESTS $PASSED passed"
    exit 4
fi
echo "VERDICT: PASS $PASSED passed"
exit 0
