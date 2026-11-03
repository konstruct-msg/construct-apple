#!/usr/bin/env python3
"""What a tester's build compiles with.

Beta is TestFlight (iOS) and the Desktop Beta DMG. Until 2026-11-03 `Beta.xcconfig` added `DEBUG`,
so every developer screen, override and test seam behind `#if DEBUG` shipped to testers, and the
project-level Beta configuration added it a second time for every target without an xcconfig.
The owner's rule since then: Beta behaves as Release, and the one thing testers get on top is the
log file and its export, under `INTERNAL_TOOLS`.

Fails when:
  * a Beta or Release configuration, in project.pbxproj or an xcconfig, compiles with `DEBUG`;
  * Release compiles with `INTERNAL_TOOLS`;
  * a Beta configuration of a target that ships (the app, Desktop) does not resolve to
    `INTERNAL_TOOLS` — without it the tester has no log to send;
  * `INTERNAL_TOOLS` gates code anywhere other than the sites listed in TESTER_SITES. A new
    tester surface is the owner's decision; record it there with the decision.

Run from anywhere; CI runs it through scripts/check_all.sh.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "ConstructMessenger.xcodeproj", "project.pbxproj")
CONFIG_DIR = os.path.join(ROOT, "ConstructMessenger")

# Targets whose Beta build reaches testers.
SHIPPED_TARGETS = ("Construct Messenger", "Construct Desktop")

# Every `#if … INTERNAL_TOOLS` line, by file, and why it is a tester surface. Counted exactly: a
# site that goes away is removed here too, so the list never describes code that is gone.
TESTER_SITES = {
    "ConstructMessenger/Utilities/LogCollector.swift": 1,           # the log file itself
    "ConstructMessenger/Utilities/Logger.swift": 1,                 # debug-level lines in it
    "ConstructMessenger/Views/Settings/SettingsView.swift": 2,      # Settings → the log screen
    "ConstructMessenger/Views/Onboarding/OnboardingView.swift": 1,  # export before an account
    "ConstructMessenger/Views/Onboarding/RecoveryEntryView.swift": 1,  # export during recovery
    "ConstructMessenger/Networking/gRPC/EngineQuicTransport/QuicClientTransport.swift": 2,  # QUIC stats lines in the log
    "ConstructMessenger/Utilities/Constants.swift": 1,              # the BETA label on the version
}

errors = []


def conditions(value):
    return set(value.replace('"', "").split())


def parse_xcconfig(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("//", 1)[0].strip()
            m = re.match(r"([A-Z_]+)\s*=\s*(.*)", line)
            if m:
                out[m.group(1)] = m.group(2).strip()
    return out


def parse_pbxproj(text):
    configs = {}
    for m in re.finditer(r"\n\t\t(\w+) /\* (\w+) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};", text, re.S):
        cid, name, body = m.groups()
        cond = re.search(r"SWIFT_ACTIVE_COMPILATION_CONDITIONS = (\"[^\"]*\"|[^;]*);", body)
        base = re.search(r"baseConfigurationReferenceRelativePath = ([^;]*);", body)
        configs[cid] = {
            "name": name,
            "cond": cond.group(1) if cond else None,
            "xcconfig": base.group(1).strip('"') if base else None,
        }
    lists = {}
    for m in re.finditer(r'/\* Build configuration list for (\w+) "([^"]+)" \*/ = \{.*?buildConfigurations = \((.*?)\);', text, re.S):
        kind, owner, ids = m.groups()
        lists[(kind, owner)] = re.findall(r"(\w+) /\*", ids)
    return configs, lists


def own_value(cfg):
    """The configuration's own setting over its xcconfig's (`$(inherited)` in the setting reaching
    the xcconfig, as Xcode resolves it); None when it only inherits from the level above."""
    base = None
    if cfg["xcconfig"]:
        base = parse_xcconfig(os.path.join(CONFIG_DIR, cfg["xcconfig"])).get("SWIFT_ACTIVE_COMPILATION_CONDITIONS")
    if cfg["cond"] is None:
        return base
    if base is None:
        return cfg["cond"]
    return cfg["cond"].replace("$(inherited)", base)


def check_configurations():
    with open(PBXPROJ, encoding="utf-8") as f:
        configs, lists = parse_pbxproj(f.read())
    if not configs or not lists:
        errors.append("project.pbxproj: no build configurations parsed — the check would pass vacuously")
        return

    project = [k for k in lists if k[0] == "PBXProject"]
    if len(project) != 1:
        errors.append(f"project.pbxproj: expected one project configuration list, found {len(project)}")
        return
    project_by_name = {configs[c]["name"]: configs[c] for c in lists[project[0]]}

    def resolve(cfg):
        own = own_value(cfg)
        parent = own_value(project_by_name[cfg["name"]]) if cfg["name"] in project_by_name else None
        parent = (parent or "").replace("$(inherited)", "")
        if own is None:
            return conditions(parent)
        return conditions(own.replace("$(inherited)", parent))

    for (kind, owner), ids in sorted(lists.items()):
        for cid in ids:
            cfg = configs[cid]
            name = cfg["name"]
            if name not in ("Beta", "Release"):
                continue
            where = f'{owner} / {name}' + (f' ({cfg["xcconfig"]})' if cfg["xcconfig"] else "")
            got = resolve(cfg) if kind == "PBXNativeTarget" else conditions((own_value(cfg) or "").replace("$(inherited)", ""))
            if "DEBUG" in got:
                errors.append(f"{where} compiles with DEBUG — testers would get every #if DEBUG surface")
            if name == "Release" and "INTERNAL_TOOLS" in got:
                errors.append(f"{where} compiles with INTERNAL_TOOLS — the App Store build would write a log file")
            if name == "Beta" and kind == "PBXNativeTarget" and owner in SHIPPED_TARGETS and "INTERNAL_TOOLS" not in got:
                errors.append(f"{where} does not compile with INTERNAL_TOOLS — testers would have no log to send")

    for target in SHIPPED_TARGETS:
        if ("PBXNativeTarget", target) not in lists:
            errors.append(f'project.pbxproj: no target "{target}" — update SHIPPED_TARGETS')


def check_tester_sites():
    out = subprocess.run(
        ["git", "-C", ROOT, "grep", "-n", "-E", r"^[[:space:]]*#(if|elseif)[[:space:]].*INTERNAL_TOOLS", "--", "*.swift"],
        capture_output=True, text=True,
    )
    if out.returncode not in (0, 1):
        errors.append(f"git grep failed: {out.stderr.strip()}")
        return
    found = {}
    for line in out.stdout.splitlines():
        path = line.split(":", 1)[0]
        found[path] = found.get(path, 0) + 1
    if not found:
        errors.append("no INTERNAL_TOOLS site found — the log export is gone, or the search is broken")
    for path in sorted(set(found) | set(TESTER_SITES)):
        want, got = TESTER_SITES.get(path, 0), found.get(path, 0)
        if got > want:
            errors.append(f"{path}: {got} INTERNAL_TOOLS site(s), {want} allowed — Beta gives testers the log "
                          f"export only (owner, 2026-11-03); anything else is #if DEBUG")
        elif got < want:
            errors.append(f"{path}: {got} INTERNAL_TOOLS site(s), TESTER_SITES says {want} — update the list")


check_configurations()
check_tester_sites()
if errors:
    for e in errors:
        print(f"  ✗ {e}")
    print("\nBuild conditions: Beta must be Release plus the log export (INTERNAL_TOOLS), never DEBUG.")
    sys.exit(1)
print("Build conditions: Beta = Release + INTERNAL_TOOLS (log export); no DEBUG in Beta or Release")
