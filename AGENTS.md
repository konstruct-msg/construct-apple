# AGENTS.md — Construct Messenger

Operational rules for AI coding agents in this repository. This file holds only the hard
invariants; details live in the docs vault `~/Code/construct-docs` — follow the links per section
and read the linked doc **before** working in that area.

---

## Project Overview

Construct Messenger is a privacy-first E2EE messenger with a terminal/ASCII aesthetic.
The cryptographic core is written in Rust (`construct-core`, separate repo) and exposed to
Swift via UniFFI bindings. The iOS app is SwiftUI-only.

## Repository Structure

```
construct-messenger/
├── ConstructMessenger/          # iOS SwiftUI app
│   ├── Utilities/               # CT design system tokens (ConstructTheme.swift, ConstructRowComponents.swift)
│   ├── Views/                   # SwiftUI views
│   ├── ViewModels/              # @Observable ViewModels
│   ├── Services/                # Session, messaging, healing, crypto orchestration
│   ├── Networking/gRPC/         # gRPC channel + generated protobuf Swift files
│   └── en.lproj/ ru.lproj/ ja.lproj/  # Localized strings
├── ConstructCore.xcframework/      # Built Rust crypto core + VEIL (NOT in git)
├── ConstructTransport.xcframework/ # Built Rust transport (NOT in git)
└── AGENTS.md                    # This file
```

Sibling repos: `~/Code/construct-core` (crypto), `~/Code/construct-transport` (QUIC/H3/gRPC),
`~/Code/construct-veil` (obfuscation proxy), `~/Code/construct-docs` (docs vault).

**Tools**: `./tools/project_index` — one-line-per-file map of the project (works on other repos too).

## Build

**Full guide (first build, target flags, gotchas)**: `~/Code/construct-docs/client/ios/BUILD_GUIDE.md`

```bash
./build_crypto_lib.sh --all      # first build: ConstructCore.xcframework (iOS+sim+mac)
./build_transport_lib.sh         # first build: ConstructTransport.xcframework
./build_crypto_lib.sh --ios      # quick rebuild after Rust changes (~45s)

xcodebuild -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build   # or `test`
```

The `*.xcframework` binaries are NOT in git — after a fresh clone they must be built before
Xcode can compile the app.

## Design System (CRITICAL — read before touching any UI)

**Full rules (symbols, platform conventions, components, migration)**:
`~/Code/construct-docs/client/ios/DESIGN_SYSTEM_RULES.md`

Hybrid language: CT terminal aesthetic + Apple HIG. Terminal glyphs are **decorative-only**:
SF Symbols + native controls for anything interactive or stateful (`CTStatusBadge`, `Toggle`,
`chevron.*`); ASCII only as chrome (`> TITLE` headers, separators). Never regress a converted
control back to ASCII.

Tokens — source of truth `ConstructMessenger/Utilities/ConstructTheme.swift`:

| Kind | API |
|------|-----|
| Colors | `Color.CT.bg`, `.text`, `.textDim`, `.accent`, `.accentDim`, `.danger`, `.noise`, `.bgMsg`, `.outMsgBg`, `.outMsgText` |
| Fonts | `CTFont.regular/medium/bold(size)` — always JetBrains Mono |
| Radii / Shapes | `CTRadius` (`badge` 6 · `card` 8 · `control` 10 · `pill` 999) via `CTShape.*()` — no magic `cornerRadius: 16|18|22` |
| Layout | `CTLayout` (`edgePad` 12 · `controlHeight` 42 · `hitTarget` 44 · …) |
| Glass | `.glassCapsule()` — defaults to pill; do not pass 18/22 |

Hard rules:

- Two surface languages, never mixed on one control: **form/card** (`CTRadius.card`, solid) vs
  **composer/glass** (`pill`, `.glassCapsule()`); `CTButton`/bubbles use `CTRadius.control`.
- **NO NavigationStack** inside sheets — `CTNavBar(showBack: true, backAction: { dismiss() })`.
- Background always `Color.CT.bg` (`#090909`) via `.ctBackground()`.
- New UI must use tokens; when editing a file with literal `8`/`10`/`18`, migrate that call site.
- Debug-only UI: `.orange`, `#if DEBUG`.
- Tab bar is the standard SwiftUI `TabView`; hide in a conversation only via
  `.toolbar(.hidden, for: .tabBar)` on the `ChatView` destination.

## Localization

- **ALL** visible strings MUST use `NSLocalizedString("key", comment: "")` — no hardcoded English.
- New keys go to **both** `en.lproj` and `ru.lproj` `Localizable.strings` in the same commit
  (`ja.lproj` planned; app name **共創**).
- Nav titles: `CTNavBar` applies `.uppercased()` + `.tracking(4)` — pass the raw localized string.

## Product language & glossary

**Full glossary**: `~/Code/construct-docs/client/GLOSSARY_PRODUCT_LANGUAGE.md`

- UI copy = plain language (orientation-screen tone): "people / chats / device", never
  "node / stream / replica" in visible strings. Code identifiers keep domain names — no renames.
- **VEIL vs WebRTC ICE — never confuse**: VEIL = our obfuscation layer (`Veil*` / `veil_*`,
  `Networking/gRPC/VEIL/`); WebRTC ICE = call NAT traversal (`Services/Calls/`, `Ice*`) and stays
  named "ICE".

## Architecture

**Full notes (session lifecycle, keychain, tab bar, crypto/transport path)**:
`~/Code/construct-docs/client/ios/ARCHITECTURE_NOTES.md`

> **Before making any architectural decision**, search the vault first:
> `grep -ril <topic> ~/Code/construct-docs/{architecture,backend,client,cryptocore,security,decisions}`
> Before touching `Networking/gRPC/ICE/`, check `decisions/ice-connection-loop-complexity.md`.

Invariants you must not violate:

- **INITIATOR vs RESPONDER init paths are distinct** (`init_session` vs
  `init_receiving_session`); tie-break: higher deviceId wins as INITIATOR. Read the notes doc
  before touching session init/healing code.
- **Keychain**: any crypto state that must survive a background/locked push decrypt uses
  `kSecAttrAccessibleAfterFirstUnlock*` (`KeychainManager.cryptoKeyAccessible`), never
  `WhenUnlocked*` — otherwise silent session desync / END_SESSION teardown of healthy sessions.
- Device keys are deleted only on gRPC UNAUTHENTICATED (16) / PERMISSION_DENIED (7) — never on
  network errors.
- **All crypto goes direct via UniFFI (`ConstructCore.xcframework`)** on both iOS and macOS
  Desktop. The old `construct-engine` / `EngineAdapter` single-binary concept is **retired and
  removed** (2026-07-28) — do not reintroduce it. The app links three Rust products merged into
  two xcframeworks: core+veil → `ConstructCore`, transport → `ConstructTransport`.
- **Generated files are never edited by hand**: `construct_core.swift`
  (`./generate_swift_bindings.sh`), `Networking/gRPC/Generated/` (`./generate_grpc_swift.sh`).

## Code Conventions

- `@Observable` for ViewModels (not `ObservableObject`); `@MainActor` on ViewModels and
  UI-touching services.
- `#if DEBUG` / `#if os(iOS)` guards where appropriate.
- No inline magic numbers — `CT.*` tokens or named constants.
- Comment only non-obvious logic.

## Binary Data Pipeline (CRITICAL — no redundant encodings)

Construct uses a fully binary pipeline. Full rationale + CFE format:
`~/Code/construct-docs/client/construct-ffi-binary-format.md`

1. **No base64 in application logic** — only at true text-transport boundaries (QR, deep links,
   `mailto:`). Never in message processing, session management, or storage.
2. **No JSON for binary payloads** — keys/ciphertexts/wire payloads are `Data` / `[UInt8]`
   end-to-end; use protobuf `bytes` or CFE binary.
3. **UniFFI boundary passes `Data` / `[UInt8]`** — never stringify; UDL fields holding binary are
   `sequence<u8>`, not `String`.
4. **Session state persists as CFE envelopes** — every `Action::SaveSessionToSecureStore` data
   field originates from `export_session_bytes_for`, never `export_session_json_for`.
5. `Codable` `Data` fields (implicit base64 in JSONEncoder) are fine for UserDefaults persistence;
   never add manual `.base64EncodedString()` / `Data(base64Encoded:)` around typed `Data`.
6. Core Data `encryptedContent` is `Binary Data` (external storage); `ChatMessage.content` is
   `Data` — control messages use `Data()`, never a string literal.

Before adding any crypto/messaging field: is it `Data` source-to-destination, `[UInt8]` across FFI,
proto `bytes`, zero base64 in the path? If not, fix the design before merging.

## User Identity Spaces (CRITICAL — two distinct ID formats)

| Type (`Utilities/UserIdentity.swift`) | Format | Correct use |
|------|--------|-------------|
| `ServerUserId` | 36-char UUID `14f28d31-…` | All session addressing: `local_user_id`, `contact_id`, `conversation_id`, contact lists |
| `CryptoDeviceId` | 32-char hex `6f5e37ac…` | Multi-device linking, QR codes ONLY |

**Invariant**: everything passed to the Rust session layer (`init_session`,
`init_receiving_session`, `set_local_user_id`) MUST be a `ServerUserId`. Mixing the spaces breaks
the Double Ratchet AD → permanent AEAD failure on every session (postmortem in construct-docs).

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`,
`refactor(scope): …`, `chore(scope): …`.

## Documentation & session notes

All docs live in `~/Code/construct-docs` (Obsidian vault, flat domain folders:
`architecture/ backend/ client/ cryptocore/ security/ decisions/ sessions/ …`).
**The vault's `AGENTS.md` is authoritative** for structure and writing rules — read it before
contributing docs. If a path is missing, search the domain folder rather than trusting old links.

After any session with architectural changes, design decisions, root-cause analysis, or
non-obvious choices:

1. Write a session note `sessions/YYYY-MM-DD-<topic>.md` (sections: Context / What Changed /
   **Why** / Decisions / Open Questions) — `## Why` with rejected alternatives is mandatory.
2. If it constrains future work, add/update `decisions/<slug>.md`.
3. Patch the affected spec in its domain folder in the **same** session.
4. Append one line to `~/Code/construct-docs/log.md`: `[YYYY-MM-DD HH:MM] note | <topic>`.

There is no raw/→wiki pipeline anymore — patch docs directly.
