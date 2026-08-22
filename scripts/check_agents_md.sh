#!/usr/bin/env bash
#
# Every path AGENTS.md names must exist.
#
# AGENTS.md is the one file an agent is guaranteed to read, and it is the one file nothing was
# checking. On 2026-08-22 four of its facts were wrong: two counts that had drifted (`53 #Preview
# blocks` when there were 76; `966 keys` when there were 995), one vault link that had moved
# (`client/construct-ffi-binary-format.md` → `client/shared/…`), and one rule pointing at a
# directory deleted three months earlier — "Before touching `Networking/gRPC/ICE/`", renamed to
# VEIL on 2026-05-29 by the very change the same file warns about seven lines above it.
#
# A rule whose trigger path does not exist is not a weak rule; it is an unreachable one, and it
# reads as live until someone goes looking. Counts are not checked here — they were removed
# instead, for the reason `fastlane/metadata/README.md` already gives about copy: never state a
# number that also lives in code.
#
# Run from the repo root. CI runs it (`checks.yml`) because it needs no build.
#
set -euo pipefail

cd "$(dirname "$0")/.."
DOC="AGENTS.md"
VAULT="${CONSTRUCT_DOCS:-$HOME/Code/construct-docs}"
fail=0

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_dim() { printf '\033[2m%s\033[0m\n' "$*"; }

# Decided before the loop, not excused after it. The vault is a sibling repository and is simply
# not checked out on CI; reporting its links as broken there and then exiting 0 anyway prints a
# red line that means nothing, which is how a check teaches people to skim it.
check_vault=1
if [ ! -d "$VAULT" ]; then
    check_vault=0
    c_dim "vault not found at \$VAULT — vault links unchecked (set CONSTRUCT_DOCS to check them)"
fi

# Named as absent, deliberately. Each is a path the file talks about *because* it is gone, so
# "does not exist" is the correct state and the check must not report it. If one comes back, the
# paragraph describing it has become wrong in the other direction — which is why this list fails
# loudly on a present path rather than staying quiet.
KNOWN_ABSENT="ConstructUI/"

# Paths inside backticks that look like files or directories: a slash or a known extension, and
# no spaces, globs, placeholders or call parentheses (`CTFont.regular/medium/bold(size)` is an
# API, `<topic>` and `*.xcframework` are prose).
paths=$(grep -oE '`[^`]+`' "$DOC" \
    | tr -d '`' \
    | grep -E '(/|\.(md|sh|swift|yml))' \
    | grep -vE '[ *<>|()]' \
    | sort -u)

# Where a path may legitimately live. AGENTS.md writes source paths relative to the app target as
# often as to the repo root, and both readings are correct in context.
resolve() {
    local p="$1" cand
    p="${p/#\~/$HOME}"
    case "$p" in
        /*) [ -e "$p" ] && { echo "$p"; return 0; } ;;
        decisions/*|sessions/*|architecture/*|backend/*|client/*|cryptocore/*|security/*)
            # A bare domain folder in this file always means the vault.
            [ -e "$VAULT/$p" ] && { echo "$VAULT/$p"; return 0; } ;;
    esac
    for cand in "$p" "ConstructMessenger/$p" "$VAULT/$p"; do
        [ -e "$cand" ] && { echo "$cand"; return 0; }
    done
    # A bare filename (`ConstructTheme.swift`) is named without its directory on purpose — it is
    # the file, wherever it sits. Accept it if exactly that name exists somewhere tracked.
    case "$p" in
        */*) return 1 ;;
        *) git ls-files "*/$p" "$p" 2>/dev/null | head -1 | grep -q . && { echo "(tracked)"; return 0; } ;;
    esac
    return 1
}

is_vault_path() {
    case "$1" in
        \~/Code/construct-docs/*|decisions/*|sessions/*|architecture/*|backend/*|client/*|cryptocore/*|security/*)
            return 0 ;;
        *) return 1 ;;
    esac
}

while IFS= read -r p; do
    [ -z "$p" ] && continue
    if [ "$check_vault" -eq 0 ] && is_vault_path "$p"; then
        continue
    fi
    if [ "$p" = "$KNOWN_ABSENT" ]; then
        if [ -e "$p" ]; then
            c_red "  ✗ $p exists, but AGENTS.md describes it as removed"
            c_dim "      update the paragraph, or drop it from KNOWN_ABSENT here"
            fail=1
        fi
        continue
    fi
    if ! resolve "$p" >/dev/null; then
        c_red "  ✗ $p"
        fail=1
    fi
done <<< "$paths"

if [ "$fail" -eq 0 ]; then
    if [ "$check_vault" -eq 1 ]; then
        c_grn "AGENTS.md: every referenced path exists"
    else
        c_grn "AGENTS.md: every repo-local path exists"
    fi
else
    echo
    c_red "AGENTS.md references paths that do not exist."
    c_dim "Fix the path, or delete the rule — a rule nothing can trigger is not a rule."
    exit 1
fi
