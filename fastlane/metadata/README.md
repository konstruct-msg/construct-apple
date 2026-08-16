# App Store listing copy

The four store locales, in the directory layout `fastlane deliver` reads. Fastlane is
not a dependency — these are plain text files, and the layout is here so that the
listing has a reviewable source in git instead of living only in App Store Connect,
where a change leaves no trace and no diff.

`scripts/check_appstore_metadata.sh` enforces Apple's field limits and locale parity.
It exists because App Store Connect reports a too-long field at upload, which is the
wrong end of the process: by then the copy has been written, reviewed and translated
four times.

| File | Limit | Notes |
|---|---|---|
| `name.txt` | 30 | Shown under the icon. Per-locale on purpose — the product name differs by script. |
| `subtitle.txt` | 30 | Under the name on the product page. |
| `promotional_text.txt` | 170 | The only field changeable **without review**. Keep anything time-sensitive here. |
| `description.txt` | 4000 | |
| `keywords.txt` | 100 | Comma-separated, **no spaces after commas** — a space costs a character. Words already in `name` and `subtitle` are indexed anyway; repeating them here wastes the budget. |
| `release_notes.txt` | 4000 | "What's New". |

Not stored here: screenshots, the privacy questionnaire, age rating, the support and
marketing URLs. Those live in App Store Connect and change on a different clock.

## Rules for this copy

- **No claim we cannot show today.** No "audited", no "quantum-safe", no VEIL or
  censorship-circumvention language. `marketing/AppStore texts.md` in the vault lists
  what was deliberately left out and why; read it before adding a line.
- **No protocol jargon.** Sealed sender, Double Ratchet, X3DH and UniFFI are for the
  whitepaper. The card is read by someone deciding in four seconds.
- **No number that lives in code.** An invite TTL or a retention window written here
  goes stale silently — the same defect that had the onboarding screen promising a
  5-minute invite for three days after the constant became 12 hours.
- One product name per script: `Konstruct`, `Конструкт`, `コンストラクト`.
