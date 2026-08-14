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
