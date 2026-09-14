# Testing — repo-local tooling

The **method** (extract the decision, name the test after the incident, pin what must not fire,
verify by mutation, state what is not covered) is a project decision and lives in the vault:
`~/Code/construct-docs/decisions/testing-by-pure-decision.md`. Read it before writing tests.

This file holds only what is specific to this repository's tools — the parts that would rot if
they lived anywhere but next to the scripts.

---

## Running one class (mutation verification)

```bash
scripts/test_run.sh ConstructMessengerTests/FooTests
```

Scoped, no simulator clones (~40s vs ~65s). It separates "build did not complete" from "no test
failed", and if the build wedges it writes a diagnosis (last command, disk, process list, `sample`
of the build service) instead of dying silently at your timeout.

Six such wedges between 2026-08-08 and 2026-08-10 cost two mutations their verification; the cause
is not yet known, so the script captures evidence for the next one.

## Running a mutation battery

A scripted battery — apply mutation, build, run, restore, repeat — lied three different ways in one
session on 2026-08-28, every time in the direction of "all killed". None of the three resembled the
others, so the rules below are mechanical rather than a matter of care.

**The baseline run is part of the battery.** It goes first and must be completely green. Without it
"mutation killed" means nothing: a battery whose first run died mid-build left its mutation in
the tree, the next script snapshotted *that* as its restore copy, and five runs then went on top of
a sixth, invisible mutation. The tell was one test red in every run including the clean one.

**Prove the restore copy on the way in.** `grep -q` for the unmutated line before starting, and
fail loudly if it is missing. And restore from that copy, never `git checkout --` — a file dirty
with real uncommitted work loses it (that is how a fix vanished mid-battery and had to be
re-applied).

**Rebuild after the final restore.** `test-without-building` reuses the last built product, which
is the last *mutation's* product. Two tests "failed" on a restored tree because the binary still
held the mutation.

**An unapplied mutation must stop the battery.** A `python3 -c` whose `assert` on the anchor fails
still lets the wrapper print its "nothing went red" line — which reads exactly like a killed
mutation. Check the exit status, or make the failure fatal.

**One battery at a time per file.** Source-text assertions read the file at test time; two batteries
overlapping on one file produce a red that belongs to neither.

**A mutation the tests cannot reach is not killed.** `isOurOwnAccount` was mutated in the production
line `userId == AuthSessionManager.shared.currentUserId`, which no test reaches — the
`ownAccountOverrideForTesting` branch returns first. The report read as "killed by another test".
Mutate the branch the tests actually execute, and record that the shadowed line stays uncovered.

## Counting tests

`xcodebuild … test` prints a line per test, and a retried clone prints some twice. Count
**unique**:

```bash
xcodebuild -scheme ConstructMessenger -destination 'platform=iOS Simulator,name=iPhone 17' test \
  2>&1 | grep -oiE "^Test case '[^']+' passed" | sort -u | wc -l
```

**`-i` is not optional.** The two run modes print different text: parallel clones print
`Test case 'FooTests.testBar()' passed`, a `-parallel-testing-enabled NO` run prints
`Test Case '-[ConstructMessengerTests.FooTests testBar]' passed`. Case-sensitively this command
answers **0** for a run where everything passed — the same shape of lie as a build failure reading
like "no test failed".

## The scheme matters

`ConstructMessenger` is the only scheme with the test target attached. `Construct Messenger Beta`
also carries it; a scheme that builds the app alone would run zero tests and report success.

## What CI does and does not cover

`.github/workflows/checks.yml` runs `check_localization.sh` (ubuntu) and
`check_privacy_manifest.sh` (macOS, needs `plutil`). That is all of it.

There is **no build or test job**, because the app links `ConstructCore.xcframework` and
`ConstructTransport.xcframework`, which are not in git and come from cross-compiling sibling Rust
repositories. A green CI badge therefore says nothing about whether the app compiles or the suite
passes — those are local, via `test_run.sh` or a full `xcodebuild test`.

## Localization

```bash
scripts/check_localization.sh
```

Enforces the AGENTS.md rule that a new key lands in both `en.lproj` and `ru.lproj`, that no key is
declared twice in one file, and that every literal `NSLocalizedString("…")` key in the sources
resolves. An unresolved key is displayed to the user verbatim.

The third check is a **ratchet**: twelve keys were already unresolved when the script was written
(`DEVELOPER`, `PUSH_NOTIFICATIONS`, `text_size`, `transcription`, the `stt_error_*` and `spam_*`
pairs, and more) and are listed in `BASELINE` so the check could be enabled the same day rather
than after someone wrote twelve strings of product copy. It fails on a new one, and it also fails
if a `BASELINE` entry starts resolving — a fixed key left in the list would hide the next
regression behind it.

Both behaviours were verified by mutation: an injected `NSLocalizedString("mutation_probe_key")`
and a key deleted from `ru.lproj` each turned the script red, and it went green again on restore.

## Privacy manifest

```bash
scripts/check_privacy_manifest.sh
```

Derives which required-reason APIs the source actually calls and fails if `PrivacyInfo.xcprivacy`
does not declare them. **Run it before any archive**: Apple checks this on the binary at upload
(ITMS-91053), so a gap surfaces after the build, after the archive, at the worst moment.

The manifest is hand-audited and the code is not. On 2026-08-11 the header read
"audited 2026-07-24" and was accurate for that date, while `ProcessInfo.systemUptime` had arrived
in the diagnostics on 2026-08-08. A document re-derived by hand every time someone adds a line
will drift again; this derives it in a second.

## Network diagnostics (`tests/`)

Python probes for the server/VEIL path, run from a laptop against a live deployment — not part of
the Xcode suite and not run by CI:

| Script | Answers |
|---|---|
| `tests/server_connectivity/test_connectivity.py` | can this host reach the gRPC endpoints at all |
| `tests/server_connectivity/test_bidi_soak.py` | does a bidirectional stream survive a long run |
| `tests/server_connectivity/check_relay.py` | is a VEIL relay reachable and serving |
| `tests/server_connectivity/run_device_path.sh` | the path a device takes, end to end |
| `tests/dpi_probe.py` | what a DPI middlebox does to our traffic |
| `tests/msk_relay_diag.py` | relay diagnosis from inside a filtered network |

See `tests/server_connectivity/README.md`.
