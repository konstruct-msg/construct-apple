#!/usr/bin/env bash
# check_appstore_metadata.sh — Apple's App Store field limits, enforced before upload.
#
# App Store Connect reports a too-long field when you upload, which is the wrong end of
# the process: by then the copy has been written, reviewed and translated into every
# locale. A subtitle that is two characters over in Japanese is cheap to fix while it is
# still a file and expensive once it is a release blocker.
#
# Three checks:
#
#   1. Every locale carries the same set of files. A missing description silently
#      inherits the primary locale's, so a half-translated listing looks finished.
#   2. Every field is within Apple's limit, counted in CHARACTERS, not bytes — a
#      Japanese subtitle is 28 characters and 84 bytes, and `wc -c` would reject it.
#   3. keywords.txt has no space after a comma. Apple counts the space against the
#      100-character budget, and it buys nothing.
#
# Limits are Apple's as of 2026-08. If they change, the number changes here; nothing
# else in the repo encodes them.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META="$ROOT/fastlane/metadata"
FAIL=0

[ -d "$META" ] || { echo "✗ no fastlane/metadata directory"; exit 1; }

# field:limit
FIELDS=(
    "name:30"
    "subtitle:30"
    "promotional_text:170"
    "keywords:100"
    "description:4000"
    "release_notes:4000"
)

LOCALES=$(find "$META" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
[ -n "$LOCALES" ] || { echo "✗ fastlane/metadata has no locale directories"; exit 1; }

# ── 1. every locale carries every field ───────────────────────────────────────
parity_ok=1
for L in $LOCALES; do
    for entry in "${FIELDS[@]}"; do
        f="$META/$L/${entry%%:*}.txt"
        if [ ! -f "$f" ]; then
            echo "✗ $L is missing ${entry%%:*}.txt — App Store Connect would fall back to the"
            echo "  primary locale and the listing would look complete while it is not"
            FAIL=1; parity_ok=0
        fi
    done
done
[ "$parity_ok" -eq 1 ] && \
    echo "✓ all $(echo "$LOCALES" | wc -w | tr -d ' ') locales carry all ${#FIELDS[@]} fields"

# ── 2. character limits ───────────────────────────────────────────────────────
limits_ok=1
for L in $LOCALES; do
    for entry in "${FIELDS[@]}"; do
        field="${entry%%:*}"; limit="${entry##*:}"
        f="$META/$L/$field.txt"
        [ -f "$f" ] || continue
        # Trailing newlines are not part of the field; Apple counts what is submitted.
        n=$(python3 -c "import io,sys; print(len(io.open(sys.argv[1],encoding='utf-8').read().rstrip('\n')))" "$f")
        if [ "$n" -gt "$limit" ]; then
            echo "✗ $L/$field.txt is $n characters, limit $limit"
            FAIL=1; limits_ok=0
        fi
    done
done
[ "$limits_ok" -eq 1 ] && echo "✓ every field is within Apple's limit"

# ── 3. keyword formatting ─────────────────────────────────────────────────────
kw_ok=1
for L in $LOCALES; do
    f="$META/$L/keywords.txt"
    [ -f "$f" ] || continue
    if grep -q ', ' "$f"; then
        echo "✗ $L/keywords.txt has a space after a comma — each one costs a character"
        echo "  of the 100 and indexes nothing"
        FAIL=1; kw_ok=0
    fi
done
[ "$kw_ok" -eq 1 ] && echo "✓ keyword lists spend no characters on spaces"

# ── report the budget, so tight fields are visible before they are a problem ──
if [ "$FAIL" -eq 0 ]; then
    echo ""
    printf "  %-8s %-18s %s\n" "locale" "field" "used / limit"
    for L in $LOCALES; do
        for entry in name subtitle:30 promotional_text keywords; do :; done
        for entry in "${FIELDS[@]}"; do
            field="${entry%%:*}"; limit="${entry##*:}"
            case "$field" in description|release_notes) continue ;; esac
            f="$META/$L/$field.txt"
            [ -f "$f" ] || continue
            n=$(python3 -c "import io,sys; print(len(io.open(sys.argv[1],encoding='utf-8').read().rstrip('\n')))" "$f")
            printf "  %-8s %-18s %s / %s\n" "$L" "$field" "$n" "$limit"
        done
    done
fi

exit $FAIL
