#!/usr/bin/env bash
# check_ui_tokens.sh — the design-token debt may shrink, never grow (vault TODO 122).
#
# AGENTS.md says new UI uses tokens, and a file you edit migrates its literals. Nothing counted,
# and by 2026-10-06 there were 162 hand-sized SF Symbols, 41 text styles past CTFont and ~115 colour
# literals — the screen built that day added more. The colour count is coarse on purpose: it also
# catches `.orange` on debug-only surfaces (the AGENTS.md rule) and the white behind a QR code,
# which are correct; it guards the trend, not each site. Each count below has a baseline; the check fails
# when a count rises above it. When a migration lowers a count, lower its baseline in the same
# commit, so the ratchet holds what was won.
#
# No build needed; runs on CI.

set -euo pipefail
cd "$(dirname "$0")/../ConstructMessenger"

THEME="Utilities/ConstructTheme.swift"

count() {
  # A count of zero is the goal, and grep exits 1 on no match; under pipefail that ended the
  # script at the first category to reach it.
  { grep -rE "$1" --include='*.swift' . || true; } | { grep -v "$THEME" || true; } | wc -l | tr -d ' '
}

# name | pattern | baseline
CHECKS=(
  "SF Symbol sized by hand — use CTIcon.font(_:)|\.font\(\.system\(size|6"
  "text style past CTFont — use a CTFont role|\.font\(\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b|41"
  "pre-split CTFont name — use a role|CTFont\.(regular|medium|bold)\(|0"
  "colour literal — use Color.CT|(foregroundStyle|foregroundColor|background|fill|stroke|tint)\(\.?(Color\.)?(white|black|gray|red|green|blue|orange|yellow)\b|169"
)

failed=0
for entry in "${CHECKS[@]}"; do
  name="${entry%%|*}"; rest="${entry#*|}"
  pattern="${rest%|*}"; baseline="${rest##*|}"
  n=$(count "$pattern")
  if (( n > baseline )); then
    echo "✗ $name: $n (baseline $baseline). Sites, first 20:"
    grep -rnE "$pattern" --include='*.swift' . | grep -v "$THEME" | head -20 || true
    failed=1
  elif (( n < baseline )); then
    echo "✓ $name: $n — below baseline $baseline; lower it in this script"
  else
    echo "✓ $name: $n"
  fi
done
exit $failed
