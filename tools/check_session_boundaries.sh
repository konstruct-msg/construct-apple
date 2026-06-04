#!/usr/bin/env bash
# check_session_boundaries.sh
#
# Prevents ad-hoc SessionCoordinator() instantiation and direct session-lifecycle
# calls from UI / ViewModel layers.
#
# Allowed locations (whitelist):
#   - SessionCoordinator.swift             (the component itself)
#   - SessionLifecycleController.swift     (the shared façade)
#   - ChatsViewModel.swift                 (composition root)
#   - StreamLifecycleCoordinator.swift     (needs coordinator reference)
#   - ChatView.swift                       (#if DEBUG preview only)
#   - ConstructMessengerTests/             (tests)
#   - ConstructMessengerUITests/           (tests)
#   - PreviewContent/                      (preview helpers)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAIL=0

# ── Rule 1: Ad-hoc SessionCoordinator() instantiation ─────────────────────
# Disallow everywhere except whitelist.
# DEBUG previews are allowed (grep context shows they're inside #if DEBUG).

WHITELIST=(
    "ConstructMessenger/Services/Session/SessionCoordinator.swift"
    "ConstructMessenger/Services/Session/SessionLifecycleController.swift"
    "ConstructMessenger/Services/Messaging/StreamLifecycleCoordinator.swift"
    "ConstructMessengerTests/"
    "ConstructMessengerUITests/"
)

# Build exclude patterns for rg
EXCLUDE_ARGS=()
for w in "${WHITELIST[@]}"; do
    EXCLUDE_ARGS+=(--glob "!${w}")
done

# Also exclude generated and test directories globally
EXCLUDE_ARGS+=(
    --glob '!ConstructEngine.xcframework/**'
    --glob '!ConstructCore.xcframework/**'
    --glob '!**/Generated/**'
    --glob '!**/build/**'
)

RESULT=$(rg --type swift \
    "${EXCLUDE_ARGS[@]}" \
    'SessionCoordinator\(\)' \
    ConstructMessenger/ 2>/dev/null || true)

# Filter out lines that are inside #if DEBUG blocks
if [ -n "$RESULT" ]; then
    DEBUG_LINES=""
    while IFS= read -r line; do
        file="${line%%:*}"
        # Check if the file has #if DEBUG near the match
        if rg -q '#if DEBUG|previewSessionCoordinator|PreviewHelpers' "$file" 2>/dev/null; then
            # Check context — if it's a preview, allow
            linenum=$(echo "$line" | cut -d: -f2)
            context=$(sed -n "$((linenum > 5 ? linenum - 5 : 1)),$((linenum + 2))p" "$file" 2>/dev/null || true)
            if echo "$context" | rg -q '#if DEBUG|preview|Preview'; then
                continue  # allowed DEBUG/preview
            fi
        fi
        DEBUG_LINES="${DEBUG_LINES}${line}\n"
    done <<< "$RESULT"

    if [ -n "$DEBUG_LINES" ]; then
        echo -e "${RED}FAIL: Ad-hoc SessionCoordinator() detected outside whitelist:${NC}"
        echo -e "$DEBUG_LINES" | sed '/^$/d'
        FAIL=1
    fi
fi

# ── Rule 2: Direct sendEndSession on fresh coordinator ────────────────────
# Catches: SessionCoordinator().sendEndSession / .sendEndSessionToAllContacts
# These should use SessionLifecycleController.shared instead.

RESULT2=$(rg --type swift \
    "${EXCLUDE_ARGS[@]}" \
    'SessionCoordinator\(\)\.(sendEndSession|sendEndSessionToAllContacts)' \
    ConstructMessenger/ 2>/dev/null || true)

if [ -n "$RESULT2" ]; then
    echo -e "${RED}FAIL: Direct SessionCoordinator().sendEndSession* — use SessionLifecycleController.shared:${NC}"
    echo "$RESULT2"
    FAIL=1
fi

# ── Rule 3: CryptoManager.shared.hasSession from Views ────────────────────
# UI should use SessionLifecycleController.shared.hasActiveSession or derive
# state from ChatViewModel, not call CryptoManager directly.

RESULT3=$(rg --type swift \
    --glob '!ConstructMessenger/Security/**' \
    --glob '!ConstructMessenger/Services/**' \
    --glob '!ConstructMessenger/ViewModels/**' \
    --glob '!ConstructMessengerTests/**' \
    --glob '!ConstructMessengerUITests/**' \
    'CryptoManager\.shared\.hasSession' \
    ConstructMessenger/Views/ 2>/dev/null || true)

if [ -n "$RESULT3" ]; then
    echo -e "${RED}WARN: View calling CryptoManager.shared.hasSession — consider SessionLifecycleController.shared.hasActiveSession:${NC}"
    echo "$RESULT3"
    # Warning only, not a hard fail yet
fi

# ── Summary ───────────────────────────────────────────────────────────────
if [ "$FAIL" -eq 1 ]; then
    echo -e "${RED}Session boundary checks FAILED.${NC}"
    exit 1
else
    echo -e "${GREEN}Session boundary checks passed.${NC}"
    exit 0
fi
