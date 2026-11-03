#!/usr/bin/env python3
"""Symbol half of check_agents_md.sh: every identifier AGENTS.md names in backticks must exist.

Prints one line per missing symbol; empty output means all found. See check_agents_md.sh."""
import os, re, subprocess, sys
from pathlib import Path

doc = Path(sys.argv[1]).read_text()
absent = set(os.environ["KNOWN_ABSENT_SYMBOLS"].split())

IDENT = re.compile(r"^@?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)(\*)?(\(([A-Za-z_]+:)*\))?$")
checks = {}  # word -> prefix?
# Fenced blocks first: their ``` would pair with inline backticks across whole sections.
inline_text = re.sub(r"^```.*?^```", "", doc, flags=re.S | re.M)
for tok in sorted(set(re.findall(r"`([^`\n]+)`", inline_text))):
    m = IDENT.match(tok)
    if not m:
        continue
    name, star, call = m.group(1), m.group(2), m.group(3)
    if "." in name and name.split(".")[-1] in {"md", "sh", "swift", "yml", "json", "py", "plist", "udl", "resolved"}:
        continue  # a file name: the path check above owns it
    parts = name.split(".")
    labels = re.findall(r"([A-Za-z_]+):", call or "")
    words = parts + labels
    for i, w in enumerate(words):
        # A plain lowercase word (`develop`, `bytes`, `stash`) is prose, not a symbol.
        if not re.search(r"[A-Z_]", w) and not call and len(parts) == 1:
            continue
        prefix = bool(star) and i == len(parts) - 1
        checks[w] = checks.get(w, False) or prefix

EXCLUDE = [":!AGENTS.md", ":!CLAUDE.md", ":!docs/"]
CORE = Path.home() / "Code/construct-core"


def grep(word, prefix, repo=None):
    """A whole-word (or word-prefix) match in a repository's tracked files. POSIX ERE, so no \\b."""
    cmd = ["git"] + (["-C", str(repo)] if repo else []) + ["grep", "-q"]
    if prefix:
        cmd += ["-E", "(^|[^A-Za-z0-9_])" + re.escape(word)]
    else:
        cmd += ["-w", "-F", word]
    cmd += ["--"] + ([] if repo else EXCLUDE)
    return subprocess.run(cmd, capture_output=True).returncode == 0


def declared(word, repo=None):
    """For a symbol described as removed: is it *declared* again? A comment or a log string that
    names it historically is not a comeback; a type, function or case of that name is."""
    kw = "class|struct|enum|protocol|actor|typealias|extension|func|case|let|var|fn|interface|dictionary|callback"
    cmd = ["git"] + (["-C", str(repo)] if repo else []) + ["grep", "-qE",
           rf"(^|[^A-Za-z0-9_])({kw})[[:space:]]+{re.escape(word)}([^A-Za-z0-9_]|$)", "--",
           "*.swift", "*.rs", "*.udl", "*.kt", "*.proto"]
    return subprocess.run(cmd, capture_output=True).returncode == 0


bad = []
if not checks:
    # The extraction itself broke (it did once, on the ``` fences): that must not read as "all found".
    bad.append("no symbols extracted from AGENTS.md — the extraction is broken, not the file clean")
for w, prefix in sorted(checks.items()):
    snake = "_" in w and w == w.lower()
    if snake and not CORE.is_dir():
        continue  # construct-core is not checked out here (CI)
    if w in absent:
        if declared(w, CORE if snake else None):
            bad.append(f"{w} is back in the code, but AGENTS.md describes it as removed")
        continue
    found = grep(w, prefix, CORE) if snake else grep(w, prefix)
    if not found:
        bad.append(w + ("*" if prefix else "") + (" (not in construct-core)" if snake else ""))
for b in bad:
    print(b)
