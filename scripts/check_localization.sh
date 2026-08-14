#!/usr/bin/env bash
# check_localization.sh — the localization rules in AGENTS.md, enforced.
#
# Three checks, no build required:
#
#   1. en.lproj and ru.lproj declare the same key set. AGENTS.md requires a new key
#      to land in both in the same commit; nothing enforced it until now.
#   2. No key is declared twice in one file. A duplicate is silently resolved by
#      whichever line the parser reads last, so the visible string stops matching
#      the one you edited.
#   3. Every literal NSLocalizedString("…") key in the Swift sources exists in
#      en.lproj. A key that does not resolve is displayed to the user verbatim —
#      that is how `text_size` and `PUSH_NOTIFICATIONS` reached production screens.
#
# Check 3 is a ratchet, not a proof. Twelve keys were already unresolved when this
# script was written (see BASELINE below) and are listed so the check can be turned
# on today rather than after someone writes twelve strings of product copy. The
# check fails on a *new* one. Deleting a name from BASELINE after fixing it is the
# point; adding one is not.
#
# ja.lproj and fr.lproj are deliberately not checked for parity: both are partial
# translations in progress (922 and 472 of 966 keys), and iOS falls back to the
# development language per missing key. Only en/ru are release-blocking.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRINGS="$ROOT/ConstructMessenger"
FAIL=0

# Keys used in code that resolve to nothing, as of 2026-08-14. Each renders as the
# raw key on a real screen. Fix them and delete the line; never append.
BASELINE=$(cat <<'EOF'
DEVELOPER
MESSAGE_NOTIFICATIONS
PUSH_NOTIFICATIONS
backup_restore_required_message
backup_restore_required_title
spam_force_banned
spam_warning_wait
stt_error_no_model
stt_error_unavailable
text_size
transcription
trasncription
EOF
)

keys_of() { grep -oE '^"[^"]+"' "$1" | sed 's/^"//; s/"$//' | sort; }

# ── 1. en/ru parity ───────────────────────────────────────────────────────────
en_keys=$(keys_of "$STRINGS/en.lproj/Localizable.strings" | sort -u)
ru_keys=$(keys_of "$STRINGS/ru.lproj/Localizable.strings" | sort -u)

missing_ru=$(comm -23 <(echo "$en_keys") <(echo "$ru_keys"))
missing_en=$(comm -13 <(echo "$en_keys") <(echo "$ru_keys"))

if [ -n "$missing_ru" ]; then
    echo "✗ in en.lproj but not ru.lproj:"; echo "$missing_ru" | sed 's/^/    /'; FAIL=1
fi
if [ -n "$missing_en" ]; then
    echo "✗ in ru.lproj but not en.lproj:"; echo "$missing_en" | sed 's/^/    /'; FAIL=1
fi
[ -z "$missing_ru$missing_en" ] && \
    echo "✓ en/ru parity — $(echo "$en_keys" | wc -l | tr -d ' ') keys in both"

# ── 2. duplicates within a file ───────────────────────────────────────────────
for L in en ru ja fr; do
    f="$STRINGS/$L.lproj/Localizable.strings"
    [ -f "$f" ] || continue
    dupes=$(keys_of "$f" | uniq -d)
    if [ -n "$dupes" ]; then
        echo "✗ $L.lproj declares a key twice:"; echo "$dupes" | sed 's/^/    /'; FAIL=1
    fi
done
[ "$FAIL" -eq 0 ] && echo "✓ no duplicate keys in any .strings file"

# ── 3. code keys resolve ──────────────────────────────────────────────────────
code_keys=$(grep -rhoE 'NSLocalizedString\("[^"]+"' --include="*.swift" "$STRINGS" \
            | sed -E 's/NSLocalizedString\("//; s/"$//' | sort -u)
unresolved=$(comm -23 <(echo "$code_keys") <(echo "$en_keys"))
new_unresolved=$(comm -23 <(echo "$unresolved") <(echo "$BASELINE" | sort))

if [ -n "$new_unresolved" ]; then
    echo "✗ NSLocalizedString keys with no entry in en.lproj — these show as raw keys:"
    echo "$new_unresolved" | sed 's/^/    /'
    echo "  Add them to BOTH en.lproj and ru.lproj."
    FAIL=1
else
    n=$(echo "$unresolved" | grep -c . || true)
    echo "✓ no new unresolved keys ($n known, listed in BASELINE — still shown raw to users)"
fi

# A fixed key left in BASELINE hides the next regression behind it.
stale=$(comm -12 <(echo "$BASELINE" | sort) <(echo "$en_keys"))
if [ -n "$stale" ]; then
    echo "✗ BASELINE lists keys that now exist — delete them from check_localization.sh:"
    echo "$stale" | sed 's/^/    /'
    FAIL=1
fi

exit $FAIL
