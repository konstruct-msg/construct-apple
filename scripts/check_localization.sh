#!/usr/bin/env bash
# check_localization.sh — the localization rules in AGENTS.md, enforced.
#
# Four checks, no build required:
#
#   1. All four .lproj declare the same key set. AGENTS.md requires a new key to land
#      in every locale in the same commit; nothing enforced it until now.
#   2. No key is declared twice in one file. A duplicate is silently resolved by
#      whichever line the parser reads last, so the visible string stops matching
#      the one you edited.
#   3. Every literal NSLocalizedString("…") key in the Swift sources exists in
#      en.lproj. A key that does not resolve is displayed to the user verbatim —
#      that is how `text_size` and `PUSH_NOTIFICATIONS` reached production screens.
#   4. A translation carries the same format specifiers as its English source, by
#      position and by conversion type. `%@` where the caller passes an Int is not a
#      wrong word on screen, it is a crash or a garbage pointer read, and it only
#      happens in the one locale nobody on the team runs.
#
# Check 3 is a ratchet, not a proof. Twelve keys were already unresolved when this
# script was written (see BASELINE below) and are listed so the check can be turned
# on today rather than after someone writes twelve strings of product copy. The
# check fails on a *new* one. Deleting a name from BASELINE after fixing it is the
# point; adding one is not.
#
# ja.lproj and fr.lproj used to be exempt from check 1 — "partial translations in
# progress", 922 and 472 of 966 keys, with iOS falling back per missing key. They were
# completed on 2026-08-16 and are now held to the same rule, because the exemption is
# what let them fall behind: nothing reported the gap, so it grew by exactly as much as
# each release added. A locale that is allowed to lag does.

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

# ── 1. parity across every locale ─────────────────────────────────────────────
en_keys=$(keys_of "$STRINGS/en.lproj/Localizable.strings" | sort -u)
parity_ok=1
for L in ru ja fr; do
    l_keys=$(keys_of "$STRINGS/$L.lproj/Localizable.strings" | sort -u)
    absent=$(comm -23 <(echo "$en_keys") <(echo "$l_keys"))
    extra=$(comm -13 <(echo "$en_keys") <(echo "$l_keys"))
    if [ -n "$absent" ]; then
        echo "✗ in en.lproj but not $L.lproj:"; echo "$absent" | sed 's/^/    /'
        FAIL=1; parity_ok=0
    fi
    if [ -n "$extra" ]; then
        echo "✗ in $L.lproj but not en.lproj — the English entry was removed, so this"
        echo "  one resolves to nothing anyone can read:"; echo "$extra" | sed 's/^/    /'
        FAIL=1; parity_ok=0
    fi
done
[ "$parity_ok" -eq 1 ] && \
    echo "✓ en/ru/ja/fr parity — $(echo "$en_keys" | wc -l | tr -d ' ') keys in each"

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

# ── 4. format specifiers survive translation ──────────────────────────────────
#
# Compared by position and conversion type, not as raw text: Japanese reorders
# arguments with %1$d / %2$d on purpose, and that is correct, not a defect.
python3 - "$STRINGS" <<'PY' || FAIL=1
import re, sys, io, os
root = sys.argv[1]
SPEC = re.compile(r'%(?:(\d+)\$)?(l{0,2}[du]|[@fs])')
def types(s):
    out, nxt = {}, 1
    for pos, conv in SPEC.findall(s):
        if pos: out[int(pos)] = conv
        else:   out[nxt] = conv; nxt += 1
    return out
def kv(loc):
    p = os.path.join(root, f"{loc}.lproj", "Localizable.strings")
    return dict(re.findall(r'^"([^"]+)"\s*=\s*"(.*)";\s*$', io.open(p, encoding="utf-8").read(), re.M))
en, bad = kv("en"), 0
for loc in ("ru", "ja", "fr"):
    for k, v in kv(loc).items():
        if k in en and types(en[k]) != types(v):
            print(f"\u2717 {loc}.lproj/{k} does not match the English format specifiers")
            print(f"    en: {en[k]}")
            print(f"    {loc}: {v}")
            bad += 1
if bad:
    print("  A mismatched specifier is a crash in that locale, not a typo.")
    sys.exit(1)
print("\u2713 format specifiers match English in every locale")
PY

exit $FAIL
