#!/usr/bin/env python3
"""check_desktop_sources.py — a platform-only import that would break the other target's build.

ConstructMessenger/ is a file-system-synchronized group compiled into BOTH the iOS app and
Construct Desktop. Everything in it builds for macOS unless the Desktop target's
membershipExceptions in project.pbxproj names it. A new file with a bare `import UIKit` builds on
iOS, and is invisible on CI (there is no build job), and breaks Desktop the next time someone
builds it — twice in 2026-10 a shared change left the macOS target red and nobody saw it for days.

This check reads the membership from project.pbxproj, walks the #if nesting of every Swift file,
and fails on:
  - an iOS-only framework imported in a file Desktop compiles, outside an iOS guard;
  - AppKit imported in a file the iOS app compiles, outside a macOS guard.

A guard is an enclosing branch that excludes the other platform: `#if os(iOS)`,
`#if canImport(UIKit)` / `canImport(<the framework>)`, `#if !os(macOS)`, or the `#else` of
`#if os(macOS)` (and the mirror image for AppKit). It does not try to evaluate arbitrary
conditions; a condition it cannot read does not count as a guard, so the check errs toward red.

It checks imports, not API use: a UIKit symbol reached through SwiftUI without an import is
the compiler's job. It is the cheapest proxy that catches the failure that actually happened.

Usage: python3 -I scripts/check_desktop_sources.py [self-test]
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "ConstructMessenger.xcodeproj" / "project.pbxproj"
SHARED = ROOT / "ConstructMessenger"
DESKTOP_ONLY = ROOT / "Construct Desktop"

# Frameworks with no native macOS module (Mac Catalyst does not count: Desktop is AppKit).
IOS_ONLY = {"UIKit", "CallKit", "BackgroundTasks"}
MACOS_ONLY = {"AppKit"}

IMPORT_RE = re.compile(r"^\s*(?:@\w+\s+)*import\s+(?:class\s+|struct\s+|enum\s+|func\s+)?(\w+)")
DIRECTIVE_RE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


def desktop_exceptions(pbx: str) -> set:
    """Paths under ConstructMessenger/ that the Desktop target does NOT compile."""
    m = re.search(
        r'Exceptions for "ConstructMessenger" folder in "Construct Desktop" target \*/ = \{(.*?)\};',
        pbx,
        re.S,
    )
    if not m:
        raise SystemExit(
            "✗ project.pbxproj has no Desktop exception set for ConstructMessenger/ — "
            "the target layout changed; update this check"
        )
    block = re.search(r"membershipExceptions = \((.*?)\);", m.group(1), re.S)
    items = block.group(1).split(",") if block else []
    return {i.strip().strip('"') for i in items if i.strip()}


def _positive(cond: str, token: str) -> bool:
    """`token` appears in `cond` and is not negated with a leading `!`."""
    for m in re.finditer(re.escape(token), cond):
        if not cond[: m.start()].rstrip().endswith("!"):
            return True
    return False


def _negated(cond: str, token: str) -> bool:
    return re.search(r"!\s*" + re.escape(token), cond) is not None


def guards(cond: str, in_else: bool, fw: str, want: str) -> bool:
    """Does this branch exclude the platform that lacks `fw`? want = 'ios' or 'macos'."""
    cond = cond.replace(" ", "")
    if want == "ios":
        pos = ["os(iOS)", "canImport(UIKit)", f"canImport({fw})"]
        anti = "os(macOS)"
    else:
        pos = ["os(macOS)", "canImport(AppKit)", f"canImport({fw})"]
        anti = "os(iOS)"
    if not in_else:
        return any(_positive(cond, p) for p in pos) or _negated(cond, anti)
    # #else of `#if os(macOS)` is iOS-only (single-condition only; anything compound is unread).
    simple = re.fullmatch(r"(!?)(os\(\w+\)|canImport\(\w+\))", cond)
    if not simple:
        return False
    neg, atom = simple.groups()
    if neg:
        return atom in pos
    return atom == anti or (want == "ios" and atom == "canImport(AppKit)") or (
        want == "macos" and atom == "canImport(UIKit)"
    )


def violations(text: str, rel: str, check_ios_only: bool, check_macos_only: bool) -> list:
    out = []
    stack = []  # [cond, in_else]
    for n, line in enumerate(text.splitlines(), 1):
        d = DIRECTIVE_RE.match(line)
        if d:
            kind, cond = d.group(1), d.group(2).split("//")[0].strip()
            if kind == "if":
                stack.append([cond, False])
            elif kind == "elseif" and stack:
                stack[-1] = [cond, False]
            elif kind == "else" and stack:
                stack[-1][1] = True
            elif kind == "endif" and stack:
                stack.pop()
            continue
        m = IMPORT_RE.match(line)
        if not m:
            continue
        fw = m.group(1)
        if check_ios_only and fw in IOS_ONLY:
            if not any(guards(c, e, fw, "ios") for c, e in stack):
                out.append(f"{rel}:{n}: import {fw} — compiled into Construct Desktop, no iOS guard")
        if check_macos_only and fw in MACOS_ONLY:
            if not any(guards(c, e, fw, "macos") for c, e in stack):
                out.append(f"{rel}:{n}: import {fw} — compiled into the iOS app, no macOS guard")
    return out


def self_test() -> None:
    cases = [
        ("import UIKit\n", 1, 0),
        ("#if os(iOS)\nimport UIKit\n#endif\n", 0, 0),
        ("#if canImport(UIKit)\nimport UIKit\n#endif\n", 0, 0),
        ("#if !os(macOS)\nimport UIKit\n#endif\n", 0, 0),
        ("#if os(macOS)\nimport AppKit\n#else\nimport UIKit\n#endif\n", 0, 0),
        ("#if os(iOS)\n#else\nimport UIKit\n#endif\n", 1, 0),
        ("#if DEBUG\nimport UIKit\n#endif\n", 1, 0),
        ("#if os(iOS) || os(macOS)\nimport UIKit\n#endif\n", 0, 0),  # read as guarded: known gap
        ("#if os(macOS)\n#elseif os(iOS)\nimport UIKit\n#endif\n", 0, 0),
        ("@preconcurrency import CallKit\n", 1, 0),
        ("import AppKit\n", 0, 1),
        ("#if os(macOS)\nimport AppKit\n#endif\n", 0, 0),
        ("#if canImport(UIKit)\nimport UIKit\n#else\nimport AppKit\n#endif\n", 0, 0),
        ("#if os(iOS)\nimport UIKit\n#else\nimport AppKit\n#endif\n", 0, 0),
        ("import Foundation // UIKit\n", 0, 0),
    ]
    bad = 0
    for src, want_ios, want_mac in cases:
        got_ios = len(violations(src, "t", True, False))
        got_mac = len(violations(src, "t", False, True))
        if (got_ios, got_mac) != (want_ios, want_mac):
            bad += 1
            print(f"✗ self-test: {src!r} → ios={got_ios} mac={got_mac}, want {want_ios}/{want_mac}")
    if bad:
        sys.exit(1)
    print(f"desktop-sources self-test: {len(cases)} cases")


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "self-test":
        self_test()
        return 0
    excluded = desktop_exceptions(PBXPROJ.read_text())
    found = []
    shared = 0
    for path in sorted(SHARED.rglob("*.swift")):
        rel = path.relative_to(SHARED).as_posix()
        in_desktop = rel not in excluded
        shared += in_desktop
        # Every file under ConstructMessenger/ is in the iOS app (its own exceptions are not Swift).
        found += violations(path.read_text(errors="replace"), f"ConstructMessenger/{rel}", in_desktop, True)
    for path in sorted(DESKTOP_ONLY.rglob("*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        found += violations(path.read_text(errors="replace"), rel, True, False)
    stale = [e for e in excluded if e.endswith(".swift") and not (SHARED / e).exists()]
    for e in sorted(stale):
        found.append(f"project.pbxproj: Desktop exception {e} names a file that does not exist")
    for f in found:
        print("✗ " + f)
    if found:
        print(
            "\nGuard the import (`#if os(iOS)` / `#if canImport(UIKit)`), or add the file to the "
            "Desktop target's membershipExceptions if Desktop must not compile it at all."
        )
        return 1
    print(f"desktop-sources: {shared} shared Swift files, {len(excluded)} Desktop exceptions, no unguarded platform import")
    return 0


if __name__ == "__main__":
    sys.exit(main())
