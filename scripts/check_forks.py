#!/usr/bin/env python3
"""Forks this app builds against (.github/forks.json).

  check_forks.py pins       every PR: the SPM pin is the fork, at a tag cut from `base`
  check_forks.py upstream   weekly: open or update an issue when upstream released past `base`
  check_forks.py self-test  the version comparison

A fork nobody watches stays on the release it was cut from: upstream fixes never arrive, and
nobody notices until a bug that was fixed months ago shows up. `upstream` is the reminder;
`pins` keeps the list honest, so the reminder is about the version actually shipped.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORKS = ROOT / ".github" / "forks.json"
RESOLVED = ROOT / "ConstructMessenger.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PBXPROJ = ROOT / "ConstructMessenger.xcodeproj/project.pbxproj"
LABEL = "fork-upstream"


def release(tag):
    """'v2.10.1' -> (2, 10, 1); None for a pre-release or anything not plain x.y.z."""
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", tag.strip())
    return tuple(int(p) for p in m.groups()) if m else None


def is_newer(latest, base):
    a, b = release(latest), release(base)
    return a is not None and b is not None and a > b


def load():
    return json.loads(FORKS.read_text())["forks"]


def pins():
    resolved = {p["identity"]: p for p in json.loads(RESOLVED.read_text())["pins"]}
    pbx = PBXPROJ.read_text()
    errors = []
    for f in load():
        if not f.get("spm"):
            continue
        url = f"https://github.com/{f['fork']}"
        pin = resolved.get(f["name"])
        if pin is None:
            errors.append(f"{f['name']}: not in Package.resolved")
            continue
        if pin["location"].rstrip("/").removesuffix(".git") != url:
            errors.append(f"{f['name']}: Package.resolved takes {pin['location']}, forks.json says {url}")
        version = pin["state"].get("version", "")
        if version != f["pin"]:
            errors.append(f"{f['name']}: Package.resolved pins {version or pin['state'].get('revision')}, forks.json says {f['pin']}")
        if not f["pin"].startswith(f["base"] + "-construct."):
            errors.append(f"{f['name']}: pin {f['pin']} is not cut from base {f['base']}")
        if f'repositoryURL = "{url}"' not in pbx:
            errors.append(f"{f['name']}: project.pbxproj does not reference {url}")
    for e in errors:
        print(f"error: {e}")
    if not errors:
        print(f"forks: {sum(1 for f in load() if f.get('spm'))} SPM pin(s) match .github/forks.json")
    return 1 if errors else 0


def gh(*args, check=True):
    return subprocess.run(["gh", *args], check=check, capture_output=True, text=True).stdout


def latest_release(repo):
    try:
        return json.loads(gh("api", f"repos/{repo}/releases/latest"))["tag_name"]
    except subprocess.CalledProcessError:
        # No releases, only tags: the highest plain x.y.z tag.
        tags = json.loads(gh("api", f"repos/{repo}/tags?per_page=100"))
        plain = [t["name"] for t in tags if release(t["name"])]
        return max(plain, key=release) if plain else None


def upstream(dry_run):
    gh("label", "create", LABEL, "--color", "C5DEF5",
       "--description", "A forked dependency has a newer upstream release", check=False) if not dry_run else None
    open_issues = [] if dry_run else json.loads(
        gh("issue", "list", "--label", LABEL, "--state", "open", "--json", "number,title", "--limit", "100"))
    for f in load():
        latest = latest_release(f["upstream"])
        if latest is None or not is_newer(latest, f["base"]):
            print(f"{f['name']}: upstream {latest}, fork on {f['base']} — up to date")
            continue
        title = f"Fork upstream: {f['name']} {latest} released (fork on {f['base']})"
        body = (
            f"`{f['upstream']}` released **{latest}**; our fork `{f['fork']}` is cut from **{f['base']}** "
            f"(branch `{f['branch']}`, pinned as `{f['pin']}`).\n\n"
            f"Why the fork exists: {f['why']}\n\n"
            f"- Changes: https://github.com/{f['upstream']}/releases/tag/{latest}\n"
            f"- To move: cherry-pick the `Construct:` commits onto `{latest}` as `construct/{latest}`, run "
            f"`swift test`, tag `{latest}-construct.1`, then update the SPM pin, `Package.resolved` and "
            f"`.github/forks.json` in one PR (`scripts/check_forks.py pins` checks they agree).\n"
        )
        print(f"{f['name']}: upstream {latest} is newer than {f['base']}")
        if dry_run:
            continue
        mine = [i for i in open_issues if i["title"].startswith(f"Fork upstream: {f['name']} ")]
        if any(i["title"] == title for i in mine):
            continue
        if mine:
            n = str(mine[0]["number"])
            gh("issue", "edit", n, "--title", title, "--body", body)
            gh("issue", "comment", n, "--body", f"Upstream moved on to {latest}.")
        else:
            gh("issue", "create", "--title", title, "--body", body, "--label", LABEL)
    return 0


def self_test():
    assert is_newer("2.10.0", "2.9.0")
    assert is_newer("v2.9.1", "2.9.0")
    assert is_newer("3.0.0", "2.99.99")
    assert not is_newer("2.9.0", "2.9.0")
    assert not is_newer("2.8.9", "2.9.0")
    assert not is_newer("2.10.0-beta.1", "2.9.0")
    assert release("2.9.0-construct.1") is None
    print("check_forks self-test: ok")
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "pins"
    if cmd == "pins":
        sys.exit(pins())
    if cmd == "upstream":
        sys.exit(upstream(dry_run="--dry-run" in sys.argv))
    if cmd == "self-test":
        sys.exit(self_test())
    sys.exit(f"unknown command {cmd}")
