#!/bin/bash
#
# check_privacy_manifest.sh — does PrivacyInfo.xcprivacy still describe the code?
#
# Apple rejects a submission (ITMS-91053, "Missing API declaration") when the app calls a
# required-reason API that the privacy manifest does not declare. The check is on the binary, so it
# fires at upload — after the build, after the archive, at the worst possible moment.
#
# The manifest is a hand-audited document and the code is not. On 2026-08-11 the header said
# "audited 2026-07-24" and was accurate for that date; `ProcessInfo.systemUptime` had arrived in
# RuntimeDiagnostics on 2026-08-08 and in ChatScrollManager before that, and nothing connected the
# two. That is not a mistake anyone makes once — a document that must be re-derived by hand every
# time someone adds a line of code will drift again.
#
# So: derive it. Grep for the API families, compare against what the manifest declares, and fail on
# a gap. Runs in ~1s and needs no build.
#
# Usage: scripts/check_privacy_manifest.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/ConstructMessenger/PrivacyInfo.xcprivacy"
SRC="$ROOT/ConstructMessenger"
STATUS=0

[ -f "$MANIFEST" ] || { echo "✗ no privacy manifest at $MANIFEST"; exit 1; }
plutil -lint "$MANIFEST" >/dev/null || { echo "✗ manifest is not valid plist"; exit 1; }

declared() { plutil -p "$MANIFEST" | grep -q "NSPrivacyAccessedAPICategory$1"; }

# Symbols that put an app in each required-reason category. Deliberately a little broad: a false
# alarm costs one line of thought, a miss costs a rejected upload.
check() {
    local category="$1" pattern="$2"
    local hits
    hits=$(grep -rEn "$pattern" "$SRC" --include='*.swift' 2>/dev/null | grep -v "^Binary" || true)
    if [ -n "$hits" ]; then
        if declared "$category"; then
            echo "✓ $category — used and declared"
        else
            echo "✗ $category — USED BUT NOT DECLARED (ITMS-91053 on upload):"
            echo "$hits" | sed "s|$ROOT/||" | head -5 | sed 's/^/    /'
            STATUS=1
        fi
    elif declared "$category"; then
        echo "· $category — declared but no call site found (stale, or the pattern missed it)"
    fi
}

check UserDefaults   'UserDefaults\.standard|UserDefaults\('
check FileTimestamp  '\.contentModificationDate|\.creationDate|attributesOfItem|\.modificationDate'
check SystemBootTime 'systemUptime'
check DiskSpace      'volumeAvailableCapacity|systemFreeSize|NSFileSystemFreeSize|volumeTotalCapacity'
check ActiveKeyboard 'activeInputModes'

# NSPrivacyTracking=false and a non-empty domain list is a contradiction Apple enforces by blocking
# the connections at runtime rather than by failing the upload — a far worse way to find out.
TRACKING=$(plutil -extract NSPrivacyTracking raw "$MANIFEST" 2>/dev/null || echo "missing")
DOMAINS=$(plutil -extract NSPrivacyTrackingDomains raw "$MANIFEST" 2>/dev/null | head -1)
if [ "$TRACKING" = "false" ] && [ -n "${DOMAINS// /}" ] && [ "$DOMAINS" != "0" ]; then
    echo "✗ NSPrivacyTracking=false but NSPrivacyTrackingDomains is non-empty — those domains get blocked at runtime"
    STATUS=1
else
    echo "✓ NSPrivacyTracking=$TRACKING with a consistent domain list"
fi

# Collected data types. An empty array is not a blank — it is the claim "Data Not Collected", so
# it is checked the same way as the required-reason APIs: derive what the code sends off-device.
collects() { plutil -p "$MANIFEST" | grep -q "NSPrivacyCollectedDataType$1"; }

PUSH=$(grep -rEn 'registerDeviceToken|registerVoipToken' "$SRC" --include='*.swift' 2>/dev/null \
       | grep -v '/Generated/' || true)
if [ -n "$PUSH" ]; then
    if collects DeviceID; then
        echo "✓ DeviceID — push tokens registered and declared"
    else
        echo "✗ DeviceID — the app registers a push token against the account but declares no"
        echo "  DeviceID collection; that contradicts the manifest's own claim:"
        echo "$PUSH" | sed "s|$ROOT/||" | head -3 | sed 's/^/    /'
        STATUS=1
    fi
fi

# A type flagged as used for tracking while NSPrivacyTracking=false is a contradiction inside one
# file. Apple resolves it against us, and the nutrition labels would disagree with the binary.
if plutil -p "$MANIFEST" | grep -A1 'NSPrivacyCollectedDataTypeTracking' | grep -q '=> 1'; then
    if [ "$TRACKING" = "false" ]; then
        echo "✗ a collected type is marked Tracking=true while NSPrivacyTracking=false"
        STATUS=1
    fi
fi

# The App Store Connect questionnaire is the binding form; this file only has to agree with it.
# Print what to carry across rather than asking anyone to re-read the plist by hand.
echo "· declare these in App Store Connect (A2.4) — App Functionality, linked, not tracking:"
plutil -p "$MANIFEST" \
    | grep -oE '"NSPrivacyCollectedDataType[A-Za-z]+"' \
    | grep -vE 'Linked|Tracking|Purpose|DataTypes"' \
    | tr -d '"' | sed 's/NSPrivacyCollectedDataType//' | sort -u | sed 's/^/    /'

exit $STATUS
