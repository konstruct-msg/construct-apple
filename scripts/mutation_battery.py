#!/usr/bin/env python3
"""mutation_battery.py — the mutation procedure of docs/TESTING.md, as a program.

AGENTS.md rule 9: every new test is mutation-checked. Done by hand, the battery lied nine
different ways (memory: feedback_mutation_harness_false_survivors), every time toward "all
killed": a dead baseline, a restore copy taken from a mutated tree, a stale binary, an unapplied
mutation that printed "nothing went red", two batteries on one file, an edit to a scanned file
mid-run, a zsh list that ran 0 tests, a kill with no failing test named. Each of those is now a
check here rather than a thing to remember:

  - one battery per machine (a lock in $TMPDIR; the simulator and DerivedData are shared anyway);
  - every mutated file must be clean in git and match its hash at start before each mutation;
  - the baseline runs first, over every test the battery names, and must be PASS;
  - a mutation whose `find` text does not occur exactly once is FATAL, before anything runs;
  - the file is restored from the bytes read at start and its hash proved, after every run, also
    on Ctrl-C or a crash;
  - no other Swift file in the app or tests may change while the battery runs (source-scan tests
    read them at test time) — a change aborts the battery;
  - each run goes through scripts/test_run.sh, which builds, so there is no stale binary, and whose
    VERDICT is the only signal read;
  - KILLED needs a named failing test; FAIL with none (a crash) is INCONCLUSIVE, not a kill;
  - NO-TESTS, STALL or USAGE aborts: the battery cannot judge anything after that;
  - a final run on the restored tree must be PASS again.

Spec file — one block per mutation, blank line between blocks, `#` comments:

    name: deliveryReceipt routes as a call signal
    file: ConstructMessenger/Services/Messaging/ContentTypeRouting.swift
    tests: ConstructMessengerTests/ContentTypeConformanceTests
    find: case 14: return .deliveryReceipt
    replace: case 14: return .callSignal

`find`/`replace` are single lines; write `\\n` for a newline inside them. `tests` is
space-separated ids.

Usage: python3 -I scripts/mutation_battery.py SPEC [--expect-survivor NAME ...]
Exit: 0 every mutation KILLED (or listed with --expect-survivor), 1 something survived or was
inconclusive / did not compile, 2 aborted.
"""

import hashlib
import os
import re
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEST_RUN = ROOT / "scripts" / "test_run.sh"
WATCHED = [ROOT / "ConstructMessenger", ROOT / "ConstructMessengerTests"]
LOCK = Path(os.environ.get("TMPDIR", "/tmp")) / "construct-mutation-battery.lock"


class Abort(Exception):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_spec(text: str) -> list:
    muts = []
    for block in re.split(r"\n\s*\n", text):
        fields = {}
        for line in block.splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            key, sep, value = line.partition(":")
            if not sep:
                raise Abort(f"spec: not `key: value`: {line!r}")
            key = key.strip()
            if key in ("find", "replace"):
                # Only the one space after the colon goes: indentation inside the text is kept.
                fields[key] = value[1:] if value.startswith(" ") else value
            else:
                fields[key] = value.strip()
        if not fields:
            continue
        missing = {"name", "file", "tests", "find", "replace"} - fields.keys()
        if missing:
            raise Abort(f"spec block {fields.get('name', '?')!r} lacks {sorted(missing)}")
        fields["find"] = fields["find"].replace("\\n", "\n")
        fields["replace"] = fields["replace"].replace("\\n", "\n")
        fields["tests"] = fields["tests"].split()
        muts.append(fields)
    names = [m["name"] for m in muts]
    if len(set(names)) != len(names):
        raise Abort("spec: two mutations share a name")
    if not muts:
        raise Abort("spec: no mutations")
    return muts


def snapshot() -> dict:
    out = {}
    for d in WATCHED:
        for p in d.rglob("*.swift"):
            out[p] = sha(p.read_bytes())
    return out


def run_tests(ids: list, label: str) -> tuple:
    """Returns (verdict, failed test lines, tail of output)."""
    print(f"  ▸ {label}: test_run.sh {' '.join(ids)}", flush=True)
    proc = subprocess.run([str(TEST_RUN), *ids], cwd=ROOT, capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    m = re.findall(r"^VERDICT: (\S+)", out, re.M)
    verdict = m[-1] if m else "NONE"
    failed = re.findall(r"Test case '[^']+' failed", out, re.I)
    expected_exit = {"PASS": 0, "FAIL": 1, "STALL": 2, "NO-BUILD": 3, "NO-TESTS": 4, "USAGE": 5}
    if expected_exit.get(verdict) != proc.returncode:
        raise Abort(f"test_run.sh said VERDICT {verdict} but exited {proc.returncode} — not trusting either")
    return verdict, failed, "\n".join(out.strip().splitlines()[-4:])


def check_untouched(base: dict, allowed: Path = None) -> None:
    now = snapshot()
    changed = sorted(
        str(p.relative_to(ROOT))
        for p in set(base) | set(now)
        if p != allowed and base.get(p) != now.get(p)
    )
    if changed:
        raise Abort("files changed under the battery (another session, an editor?): " + ", ".join(changed[:10]))


def acquire_lock() -> None:
    try:
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        pid = LOCK.read_text().strip() or "?"
        alive = pid.isdigit() and subprocess.run(["kill", "-0", pid], capture_output=True).returncode == 0
        if alive:
            raise Abort(f"another battery is running (pid {pid}, {LOCK})")
        print(f"  (removing stale lock of dead pid {pid})")
        LOCK.unlink()
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    os.write(fd, str(os.getpid()).encode())
    os.close(fd)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 2
    spec_path = Path(args[0])
    expect_survivors = set()
    rest = args[1:]
    while rest:
        if rest[0] == "--expect-survivor" and len(rest) > 1:
            expect_survivors.add(rest[1])
            rest = rest[2:]
        else:
            print(f"unknown argument {rest[0]!r}")
            return 2

    muts = parse_spec(spec_path.read_text())
    unknown = expect_survivors - {m["name"] for m in muts}
    if unknown:
        raise Abort(f"--expect-survivor names no mutation: {sorted(unknown)}")

    # Read every target once; these bytes are the restore source, never git.
    originals = {}
    for m in muts:
        path = (ROOT / m["file"]).resolve()
        if not path.is_file():
            raise Abort(f"{m['name']}: no file {m['file']}")
        m["path"] = path
        if path not in originals:
            dirty = subprocess.run(
                ["git", "status", "--porcelain", "--", str(path)], cwd=ROOT, capture_output=True, text=True
            ).stdout.strip()
            if dirty:
                raise Abort(f"{m['file']} has uncommitted changes — commit them first, so restore cannot lose them")
            originals[path] = path.read_bytes()
        count = originals[path].decode().count(m["find"])
        if count != 1:
            raise Abort(f"FATAL unapplied: {m['name']}: `find` occurs {count}× in {m['file']} (must be exactly 1)")
        if m["find"] == m["replace"]:
            raise Abort(f"FATAL: {m['name']}: replace equals find")

    acquire_lock()
    current = {"path": None}

    def restore_current() -> None:
        p = current["path"]
        if p is not None:
            p.write_bytes(originals[p])
            if sha(p.read_bytes()) != sha(originals[p]):
                raise Abort(f"RESTORE FAILED for {p} — fix by hand before anything else")
            current["path"] = None

    def on_signal(signum, frame):
        raise Abort(f"interrupted (signal {signum})")

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    results = []
    try:
        base = snapshot()
        all_ids = sorted({t for m in muts for t in m["tests"]})
        print(f"battery: {len(muts)} mutation(s), tests: {' '.join(all_ids)}")

        verdict, failed, tail = run_tests(all_ids, "baseline")
        if verdict != "PASS":
            raise Abort(f"baseline is {verdict}, not PASS — a kill means nothing on a red baseline\n{tail}")
        check_untouched(base)

        for m in muts:
            p = m["path"]
            if sha(p.read_bytes()) != sha(originals[p]):
                raise Abort(f"{m['file']} no longer matches its start hash before {m['name']!r}")
            mutated = originals[p].decode().replace(m["find"], m["replace"], 1).encode()
            current["path"] = p
            p.write_bytes(mutated)
            if sha(p.read_bytes()) == sha(originals[p]):
                raise Abort(f"FATAL unapplied: {m['name']}: file unchanged after write")

            verdict, failed, tail = run_tests(m["tests"], m["name"])
            restore_current()
            check_untouched(base)

            if verdict == "FAIL" and failed:
                outcome = "KILLED"
            elif verdict == "FAIL":
                outcome = "INCONCLUSIVE (FAIL with no failed test case — a crash?)"
            elif verdict == "PASS":
                outcome = "SURVIVED"
            elif verdict == "NO-BUILD":
                outcome = "DID NOT COMPILE (not a kill: the mutation is invalid)"
            else:
                raise Abort(f"{m['name']}: verdict {verdict} — the battery cannot judge this run\n{tail}")
            results.append((m["name"], outcome, failed))
            print(f"    → {outcome}" + (f": {'; '.join(failed[:3])}" if failed else ""), flush=True)

        verdict, failed, tail = run_tests(all_ids, "final run on the restored tree")
        if verdict != "PASS":
            raise Abort(f"restored tree is {verdict}, not PASS\n{tail}")
    except Abort as e:
        try:
            restore_current()
        finally:
            print(f"\n✗ ABORTED: {e}")
            for name, outcome, _ in results:
                print(f"  {outcome:<10} {name}")
            LOCK.unlink(missing_ok=True)
        return 2
    except BaseException:
        restore_current()
        LOCK.unlink(missing_ok=True)
        raise
    LOCK.unlink(missing_ok=True)

    print("\nresult:")
    bad = 0
    for name, outcome, failed in results:
        ok = outcome == "KILLED" or (outcome == "SURVIVED" and name in expect_survivors)
        bad += not ok
        mark = "✓" if ok else "✗"
        note = " (expected)" if outcome == "SURVIVED" and name in expect_survivors else ""
        print(f"  {mark} {outcome}{note}  {name}" + (f"  ← {failed[0]}" if failed else ""))
    print(f"\nBATTERY: {len(results) - bad}/{len(results)} as expected; baseline and restored tree PASS")
    return 1 if bad else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Abort as e:
        print(f"✗ {e}")
        sys.exit(2)
