# AGENTS.md — Construct Messenger

Hard invariants for AI coding agents in this repository, and nothing else. Every rule here is
attached to the incident that produced it — that is why they are phrased as history rather than
style. Detail lives in the linked documents; read the one covering your area **before** working in
it.

| Area | Read first |
|---|---|
| Build, first clone, target flags | `~/Code/construct-docs/client/ios/BUILD_GUIDE.md` |
| UniFFI bindings | `~/Code/construct-docs/client/ios/UNIFFI_GUIDE.md` |
| Design system (symbols, components, migration) | `~/Code/construct-docs/client/ios/DESIGN_SYSTEM_RULES.md` |
| Session lifecycle, keychain, crypto/transport path | `~/Code/construct-docs/client/ios/ARCHITECTURE_NOTES.md` |
| Sealed control channel | `~/Code/construct-docs/client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md` |
| Binary data / CFE format | `~/Code/construct-docs/client/shared/construct-ffi-binary-format.md` |
| Product wording | `~/Code/construct-docs/client/GLOSSARY_PRODUCT_LANGUAGE.md` |
| How to test | `docs/TESTING.md` → `~/Code/construct-docs/decisions/testing-by-pure-decision.md` |
| Two-simulator E2E stand | `docs/TWO_SIM_STAND.md` |
| Everything else | `~/Code/construct-docs` (vault; its own `AGENTS.md` is authoritative) |

---

## Overview

Privacy-first E2EE messenger, terminal/ASCII aesthetic. The cryptographic core is Rust
(`construct-core`, separate repo) exposed to Swift via UniFFI. The client is SwiftUI-only.

Layout: `ConstructMessenger/` iOS app · `Construct Desktop/` macOS · `ConstructMessengerTests/` ·
`scripts/` · `tests/` Python network probes · `docs/` repo-local reference · `logs/` (gitignored).

CI (`.github/workflows/checks.yml`) runs only what needs no build: localization and the privacy
manifest. It cannot build the app — the xcframeworks are not in git and come from sibling repos —
so a green CI says nothing about compilation. Build and test locally.

Sibling repos: `~/Code/construct-core` (crypto), `~/Code/construct-transport` (QUIC/H3/gRPC),
`~/Code/construct-veil` (obfuscation), `~/Code/construct-docs` (vault).

## Build

```bash
./build_crypto_lib.sh --all      # first build: ConstructCore.xcframework (iOS+sim+mac)
./build_transport_lib.sh --all   # first build: ConstructTransport.xcframework (iOS+sim+mac)
./build_crypto_lib.sh --ios      # quick rebuild after Rust changes (~45s)
```

- **`--all` on both, always, unless you are rebuilding for one platform on purpose.** Without it
  `build_transport_lib.sh` omits the `macos-arm64` slice, and this file said to run it bare until
  2026-08-23. Nothing on the iOS side notices; `Construct Desktop/` then fails to link against an
  xcframework that looks perfectly well-formed.
- The `*.xcframework` binaries are **not** in git — a fresh clone must build them before Xcode can
  compile anything. `Info.plist` **is** tracked, which is the only reason a narrowed rebuild shows
  up as a diff at all.
- **Never pin `OS=` in a `-destination`.** Simulator runtimes are replaced with every Xcode
  upgrade; a pinned one stops resolving and the failure reads like a project problem. This file
  said `iPhone 16,OS=18.6` for months after that runtime was gone. Check
  `xcrun simctl list devices available` rather than trusting any example.
- **`ConstructMessenger` is the scheme with the test target.** A scheme that builds the app alone
  runs zero tests and reports success.

## Design system (read before touching any UI)

Hybrid language: CT terminal aesthetic + Apple HIG. Terminal glyphs are **decorative-only**: SF
Symbols and native controls for anything interactive or stateful (`CTStatusBadge`, `Toggle`,
`chevron.*`); ASCII only as chrome (`> TITLE` headers, separators). Never regress a converted
control back to ASCII.

Tokens — source of truth `ConstructMessenger/Utilities/ConstructTheme.swift`:

| Kind | API |
|------|-----|
| Colors | `Color.CT.bg`, `.text`, `.textDim`, `.accent`, `.accentDim`, `.danger`, `.noise`, `.bgMsg`, `.outMsgBg`, `.outMsgText` |
| Fonts | `CTFont.regular/medium/bold(size)` — always JetBrains Mono |
| Radii / Shapes | `CTRadius` (`badge` 6 · `card` 8 · `control` 10 · `pill` 999) via `CTShape.*()` — no magic `cornerRadius: 16\|18\|22` |
| Layout | `CTLayout` (`edgePad` 12 · `controlHeight` 42 · `hitTarget` 44 · …) |
| Glass | `.glassCapsule()` — defaults to pill; do not pass 18/22 |

- Two surface languages, never mixed on one control: **form/card** (`CTRadius.card`, solid) vs
  **composer/glass** (`pill`, `.glassCapsule()`); `CTButton`/bubbles use `CTRadius.control`.
- **No `NavigationStack` inside sheets** — `CTNavBar(showBack: true, backAction: { dismiss() })`.
- Background always `Color.CT.bg` (`#090909`) via `.ctBackground()`.
- New UI must use tokens; when editing a file with a literal `8`/`10`/`18`, migrate that call site.
- Debug-only UI: `.orange`, `#if DEBUG`.
- Tab bar is the standard SwiftUI `TabView`; hide it in a conversation only via
  `.toolbar(.hidden, for: .tabBar)` on the `ChatView` destination.

**Xcode Previews do not run in the app target.** It links WebRTC and WhisperKit, and the preview
process dies at launch with `_objc_fatal: Attempt to use unknown class` whenever those load — on
any iOS runtime, independent of app code, and compile flags cannot help because the frameworks stay
linked. Every `#Preview` block in the app is therefore decorative today.

A separate previewable package is a recurring idea and was tried once. If you rebuild it, the
theme file is **shared, never copied** — the copy is what killed the last attempt. Read
`decisions/one-theme-file-shared-not-copied.md` first.

## Localization

- **All** visible strings use `NSLocalizedString("key", comment: "")` — no hardcoded English.
- New keys go to **all four** locales — `en`, `ru`, `ja`, `fr` — in the same commit.
  `scripts/check_localization.sh` enforces parity, no duplicate keys, no key that resolves to
  nothing, and that a translation carries the same format specifiers as its English source by
  position and conversion type; CI runs it. A key with no entry is displayed to the user
  verbatim — the ones already on real screens are listed in that script's `BASELINE`, and the
  check exists to fail on a *new* one. A wrong specifier is worse than a wrong word: it crashes,
  and only in the locale nobody on the team runs.
- `ja` and `fr` were exempt from parity until 2026-08-16 as "partial translations in progress",
  and had fallen hundreds of keys behind by the time anyone counted. The exemption is what let
  that happen — nothing reported the gap, so it grew by whatever each release added. A locale
  allowed to lag does. Both are complete now and held to the same rule.
- **One product name per script.** `Konstruct` in Latin, `Конструкт` in Russian, `コンストラクト`
  in Japanese — a localized name is a transliteration, never a translation. The one deliberate
  exception is `onboarding_tagline`, where "identity is a construct" is the common noun and the
  pun. Why the Japanese changed: `client/GLOSSARY_PRODUCT_LANGUAGE.md` in the vault.
- **App Store listing copy lives in `fastlane/metadata/<locale>/`**, not only in App Store
  Connect, so a change to it has a diff and a reviewer. Read `fastlane/metadata/README.md` before
  touching it — field limits, the four store locales, and what must never go in the copy.
  `scripts/check_appstore_metadata.sh` enforces the mechanical part and CI runs it.
- Nav titles: `CTNavBar` applies `.uppercased()` + `.tracking(4)` — pass the raw localized string.
- UI copy is plain language ("people / chats / device", never "node / stream / replica"). Code
  identifiers keep domain names — no renames.
- **VEIL is not ICE.** VEIL is our obfuscation layer (`Veil*` / `veil_*`, `Networking/gRPC/VEIL/`);
  WebRTC ICE is call NAT traversal (`Services/Calls/`, `Ice*`) and stays named "ICE".

## Architecture invariants

Before any architectural decision, search the vault:
`grep -ril <topic> ~/Code/construct-docs/{architecture,backend,client,cryptocore,security,decisions}`.
Before touching `Networking/gRPC/VEIL/` or `Services/Calls/`, read
`decisions/ice-connection-loop-complexity.md` — it predates the rename below and covers both.

- **INITIATOR and RESPONDER init paths are distinct** (`init_session` vs
  `init_receiving_session`); tie-break: higher deviceId wins as INITIATOR.
- **Keychain**: crypto state that must survive a background/locked push decrypt uses
  `kSecAttrAccessibleAfterFirstUnlock*` (`KeychainManager.cryptoKeyAccessible`), never
  `WhenUnlocked*` — otherwise silent session desync and END_SESSION teardown of healthy sessions.
- Device keys are deleted **only** on gRPC UNAUTHENTICATED (16) / PERMISSION_DENIED (7) — never on
  a network error.
- **All crypto goes direct via UniFFI** (`ConstructCore.xcframework`) on iOS and macOS alike. The
  `construct-engine` / `EngineAdapter` single-binary concept was retired and removed 2026-07-28 —
  do not reintroduce it. Three Rust products, two xcframeworks: core+veil → `ConstructCore`,
  transport → `ConstructTransport`.
- **Generated files are never hand-edited**: `construct_core.swift` (`./generate_swift_bindings.sh`),
  `Networking/gRPC/Generated/` (`./generate_grpc_swift.sh`).

## Code conventions

- `@Observable` for ViewModels (not `ObservableObject`); `@MainActor` on ViewModels and
  UI-touching services.
- `#if DEBUG` / `#if os(iOS)` guards where appropriate.
- No inline magic numbers — `CT.*` tokens or named constants.
- Comment only non-obvious logic.

**A field left out on purpose at a boundary must say so in a comment.** Rebuilding a value across a
boundary (unseal, FFI, wire→model) means listing fields, and in a list of twenty an omission that
was deliberate is indistinguishable from one that was forgotten. `pqMessageEpoch` and
`pqRatchetField` were dropped at the unseal boundary and nobody could see it, precisely because the
neighbouring deliberate omission (`sealedInnerData`) *was* commented and these two were not. Better
still, give the boundary a name (`ChatMessage.resolvingSealedSender(_:currentUserId:)`) so it is an
object a test can reach rather than an argument list inside a 200-line method.

**A producer with no consumer is a defect, not dead weight.** If you add a send, a signal or an
action, the reader must exist in the same change — or the sender must be removed. An unconsumed
message still costs a ratchet advance, and it surfaces somewhere: `__session_reset_notify__`
shipped in April 2026 with no reader and spent four months writing itself into the transcript as a
visible bubble on multi-device accounts. The reverse holds too: a handler no producer reaches is
either wired up or deleted.

## Binary data pipeline (no redundant encodings)

1. **No base64 in application logic** — only at true text-transport boundaries (QR, deep links,
   `mailto:`). Never in message processing, session management or storage.
2. **No JSON for binary payloads** — keys, ciphertexts and wire payloads are `Data` / `[UInt8]`
   end to end; use protobuf `bytes` or CFE binary.
3. **The UniFFI boundary passes `Data` / `[UInt8]`** — never stringify; UDL fields holding binary
   are `sequence<u8>`, not `String`.
4. **Session state persists as CFE envelopes** — every `Action::SaveSessionToSecureStore` data
   field originates from `export_session_bytes_for`, never `export_session_json_for`.
5. `Codable` `Data` fields (implicit base64 in JSONEncoder) are fine for UserDefaults persistence;
   never add manual `.base64EncodedString()` / `Data(base64Encoded:)` around a typed `Data`.
6. Core Data `encryptedContent` is `Binary Data` (external storage); `ChatMessage.content` is
   `Data` — control messages use `Data()`, never a string literal.

Before adding any crypto or messaging field: is it `Data` source-to-destination, `[UInt8]` across
FFI, proto `bytes`, zero base64 in the path? If not, fix the design before merging.

## Two representations, one authority

This codebase's recurring defect class is **one meaning carried by two values with nothing
enforcing their agreement**. Both instances below are permanent invariants, not migrations.

**Read `~/Code/construct-docs/decisions/one-meaning-two-carriers.md` before adding any field,
counter, constant or timeout.** It catalogues the six forms this takes — two of which do not look
like duplication at all — the three mechanical detectors that find them, and the order of
preference for fixing one. The short version: hand-synchronising two carriers is not a fix, and a
comment promising that something "must match" another implementation is a comment saying it should
have been a call to it.

**User identity spaces** (`Utilities/UserIdentity.swift`):

| Type | Format | Correct use |
|------|--------|-------------|
| `ServerUserId` | 36-char UUID `14f28d31-…` | all session addressing: `local_user_id`, `contact_id`, `conversation_id`, contact lists |
| `CryptoDeviceId` | 32-char hex `6f5e37ac…` | multi-device linking, QR codes only |

Everything passed to the Rust session layer (`init_session`, `init_receiving_session`,
`set_local_user_id`) must be a `ServerUserId`. Mixing the spaces breaks the Double Ratchet AD →
permanent AEAD failure on every session.

**Sealed sender content type:**

| Layer | Field | Authoritative after unseal? |
|------|-------|------------------------------|
| Outer envelope (pre-unseal) | `messageType` / outer `content_type` | **No** — the sealed path stamps these generic on purpose |
| `SealedInner` (post-unseal) | `contentType: UInt8` | **Yes** — sole routing input |

Any routing decision on a sealed delivery must read the post-unseal `contentType` (via
`ContentTypeRouting.kind(for:)`, `ChatMessage.isEndSession`, …). Never branch on the outer
`messageType` string after `resolveSender`.

**Content-type meaning is cross-client, and this app is not its author.** There is now a second
implementation (`construct-tui`), so "the protocol" and "what iOS does" are different things, and
the first comparison found them already diverged on 13 and 23 — silently, because the symptom is a
payload that is a bubble on one client and nothing on the other.

- Numeric values come from the generated `Shared_Proto_Core_V1_ContentType`. Do not write `21` or
  `= 25` as a fresh literal; the existing switches keep theirs only because they predate this rule.
- What a client must *do* with a type — transcript or control, which handler, whether a sealed
  envelope may name it — is `~/Code/construct-protos/conformance/knst_content_types.json`, vendored
  into `ConstructMessenger/Networking/gRPC/Generated/conformance/` by `./generate_grpc_swift.sh`
  and read by `ConstructMessengerTests/ContentTypeConformanceTests.swift`.
- **Adding a content type means adding its row there in the same change.** A type this app has not
  learned then reddens a named test instead of arriving as a payload nobody classifies.
- Read `decisions/wire-format-one-authority.md` before changing any of the five mappings it lists.

## Testing

Method and tooling: `docs/TESTING.md`. The one rule that belongs here:

**The target is not a coverage number.** Coverage counts lines executed, not claims checked, and
this repo has paid the difference — `SessionQueueWiringTests` passed for five weeks asserting
nothing after a production guard began returning early; it read all-zeros and confirmed them. A
test that cannot fail is worse than no test, because it occupies the place where someone would
otherwise have looked.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`,
`refactor(scope): …`, `chore(scope): …`.

## Documentation & session notes

Docs live in `~/Code/construct-docs` (Obsidian vault, flat domain folders). **The vault's
`AGENTS.md` is authoritative** for structure and writing rules. If a path is missing, search the
domain folder rather than trusting an old link.

Repo-local `docs/` holds only what documents a file in *this* repo and must change in the same
commit as it — currently the two-simulator stand and the test tooling.

After any session with architectural changes, design decisions, root-cause analysis or non-obvious
choices:

1. Write `sessions/YYYY-MM-DD-<topic>.md` (Context / What Changed / **Why** / Decisions / Open
   Questions) — `## Why` with rejected alternatives is mandatory.
2. If it constrains future work, add or update `decisions/<slug>.md`.
3. Patch the affected spec in its domain folder in the **same** session.
4. Append one line to `~/Code/construct-docs/log.md`: `[YYYY-MM-DD HH:MM] note | <topic>`.
