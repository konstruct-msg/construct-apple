#!/usr/bin/env bash
# check_build_versions.sh — the app and its notification extension carry one version.
#
# App Store Connect requires an embedded extension's CFBundleVersion and
# CFBundleShortVersionString to match the app's. Since 2026-10-11 both come from the PROJECT's
# build settings (CURRENT_PROJECT_VERSION, MARKETING_VERSION): the two targets inherit one value
# and cannot disagree. Xcode undoes that silently. Typing a build number on a target's General
# tab writes it into that target, and from then on the app moves and the extension does not. The
# mismatch surfaces at upload, after the archive.
#
# Two checks, on ConstructMessenger.xcodeproj/project.pbxproj:
#
#   1. Neither "Construct Messenger" nor "Konstruct Notifications" sets either key in any of
#      its build configurations.
#   2. The project sets both keys in every one of its configurations, so the inherited value
#      is never Xcode's default.
#
# Construct Desktop and the test targets keep their own versions on purpose and are not checked.
#
# To bump: select the PROJECT "ConstructMessenger" (not a target) → Build Settings → Current
# Project Version / Marketing Version.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBXPROJ="$ROOT/ConstructMessenger.xcodeproj/project.pbxproj"

[ -f "$PBXPROJ" ] || { echo "✗ no $PBXPROJ"; exit 1; }

python3 - "$PBXPROJ" <<'EOF'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
KEYS = ("CURRENT_PROJECT_VERSION", "MARKETING_VERSION")
SHARED = ("Construct Messenger", "Konstruct Notifications")


def block(object_id):
    """The text of one object, from its id to the line that closes it."""
    m = re.search(r"^\t\t" + object_id + r" /\*.*?\*/ = \{\n(.*?)^\t\t\};", text, re.S | re.M)
    return m.group(1) if m else None


def configurations(list_id):
    body = block(list_id) or ""
    m = re.search(r"buildConfigurations = \((.*?)\);", body, re.S)
    if not m:
        return []
    return re.findall(r"(\w{24}) /\* (.*?) \*/", m.group(1))


def owner_list(isa, name=None):
    pattern = r"^\t\t\w{24} /\* " + (re.escape(name) if name else r"[^*]*") + r" \*/ = \{\n\t\t\tisa = " + isa + r";\n(.*?)^\t\t\};"
    m = re.search(pattern, text, re.S | re.M)
    if not m:
        return None
    lm = re.search(r"buildConfigurationList = (\w{24})", m.group(1))
    return lm.group(1) if lm else None


failures = []

for target in SHARED:
    list_id = owner_list("PBXNativeTarget", target)
    if list_id is None:
        failures.append(f'target "{target}" not found')
        continue
    for config_id, config_name in configurations(list_id):
        body = block(config_id) or ""
        for key in KEYS:
            if re.search(r"^\t\t\t\t" + key + r" = ", body, re.M):
                failures.append(f'"{target}" ({config_name}) sets {key}: delete it on the target, '
                                f"set it on the project")

project_list = owner_list("PBXProject")
project_configs = configurations(project_list) if project_list else []
if not project_configs:
    failures.append("project build configurations not found")
for config_id, config_name in project_configs:
    body = block(config_id) or ""
    for key in KEYS:
        if not re.search(r"^\t\t\t\t" + key + r" = ", body, re.M):
            failures.append(f"project ({config_name}) does not set {key}")

if failures:
    for f in failures:
        print(f"✗ {f}")
    sys.exit(1)
print("✓ the app and its extension inherit one version from the project")
EOF
