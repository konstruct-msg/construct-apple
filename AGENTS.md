# AGENTS.md — Construct Messenger

This file provides context and conventions for AI coding agents working in this repository.
Read it fully before making any changes.

---

## Project Overview

Construct Messenger is a privacy-first E2EE messenger with a terminal/ASCII aesthetic.
The cryptographic core is written in Rust (`construct-core`, separate repo) and exposed to
Swift via UniFFI bindings. The iOS app is SwiftUI-only.

---

## Repository Structure

```
construct-messenger/
├── ConstructMessenger/          # iOS SwiftUI app
│   ├── Utilities/               # CT design system tokens (ConstructTheme.swift, ConstructRowComponents.swift)
│   ├── Views/                   # All SwiftUI views
│   ├── ViewModels/              # @Observable ViewModels
│   ├── Services/                # Session, messaging, healing, crypto orchestration
│   ├── Networking/gRPC/         # gRPC channel + generated protobuf Swift files
│   ├── en.lproj/                # English strings
│   └── ru.lproj/                # Russian strings
├── ConstructCore.xcframework/   # Pre-built Rust xcframework (arm64 iOS + Simulator + macOS)
├── libconstruct_core.a          # Rust static lib (arm64 iOS)
├── libconstruct_core_sim.a      # Rust static lib (Simulator)
├── build_crypto_lib.sh          # Script to rebuild Rust library
├── construct_core.swift         # UniFFI auto-generated bindings — DO NOT EDIT
└── AGENTS.md                    # This file
```

The Rust core lives at: `/Users/maximeliseyev/Code/construct-core`

---

## Build Commands

```bash
# Build iOS app (simulator)
xcodebuild -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build

# Build Rust crypto library (run from project root)
./build_crypto_lib.sh --ios       # iOS device (arm64)
./build_crypto_lib.sh --sim       # Simulator
./build_crypto_lib.sh --ios --sim # Both

# After rebuilding Rust lib: always Clean Build Folder in Xcode (⌘⇧K)
```

---

## Design System (CRITICAL — read before touching any UI)

### Design Philosophy: CT + Apple Fusion

Construct uses a **hybrid design language**: the terminal / cyberpunk aesthetic of CT fused with
Apple's HIG conventions so that users intuitively understand how to interact with the interface.
The goal is a **bespoke look** that does not clash with iOS / macOS platform norms.

**Keep**: JetBrains Mono, `#090909` background, CT color palette, information density, ASCII
decorative elements (noise, separators, `>` section headers, `✷`, bracket glyphs).  
**Evolve**: touch affordances, icon legibility for interactive controls, bubble readability.  
**Never**: sacrifice usability or clash visibly with iOS 26 / macOS guidelines.

### Tokens
- Colors: `Color.CT.bg`, `Color.CT.text`, `Color.CT.accent`, `Color.CT.danger`, `Color.CT.noise`, `Color.CT.textDim`
- Fonts: `CTFont.regular(size)`, `CTFont.bold(size)` — always JetBrains Mono
- Symbols: `CTSymbol.*` ASCII glyphs for structural/nav elements; `Image(systemName:)` SF Symbols for interactive controls

### Rules

#### Symbols
- **SF Symbols** (`Image(systemName:)`): use for **interactive controls** — action buttons, tab bar
  items, media controls, call buttons, send button, attach, mic, search magnifying glass, close (×).
  These are universally recognised by Apple platform users and their absence causes confusion.
- **`CTSymbol.*` ASCII glyphs**: use for **structural and navigational elements** — back `[←]`,
  forward `[→]`, section headers (`> TITLE`), separators, status indicators, decorative symbols.
- Both can coexist on the same screen. The dividing line is: *does the user need to immediately
  recognise this as a tappable action?* → SF Symbol. *Is it part of the terminal aesthetic or
  navigation chrome?* → CTSymbol.

#### Shapes & Corners
- **Rounded corners**: use `RoundedRectangle(cornerRadius:)` where Apple HIG implies it —
  `cornerRadius: 10` for message bubbles and input/search fields,
  `cornerRadius: 6` for small inline badges or tags.
- **`Rectangle()`**: for nav bars, row backgrounds, list containers, full-width structural
  dividers and backdrops. Avoids the "card stack" look that clashes with CT's flat terminal feel.
- Avoid `cornerRadius > 18` except for input pill bars.

#### Other rules
- **NO NavigationStack** inside sheet/modal views — use `CTNavBar(showBack: true, backAction: { dismiss() })` + `@Environment(\.dismiss)`.
- **Background color**: always `Color.CT.bg` (`#090909`). Use `.ctBackground()` modifier.
- **Section headers**: `CTSettingsSectionHeader(title:)` — renders `> TITLE` in accent color.
- **Dividers**: `Rectangle().fill(Color.CT.noise).frame(height: 1)` (full-width) or with `.padding(.horizontal, 20)` (between rows).
- **Action rows**: trailing `[→]` / `CTSymbol.forward`, font `.regular(13)`.
- **Developer/debug UI**: use `.orange` color for all dev-facing elements.
- **Tab bar**: controlled by `ChatsViewModel.isInChat` and `ChatsViewModel.isInSettings`. Never hide/show it directly.

### Components
- `CTNavBar` — navigation bar with optional back `[←]` and trailing action
- `CTSettingsSectionHeader` — `> SECTION` header, supports `color:` parameter
- `CTSettingsRow` — label + value row, supports `labelColor:`, `valueColor:`, `isAction:`, `isDestructive:`
- `CTSep` — separator (`.thick` between sections, `.thin` between rows)
- `CTHexAvatar` / `HexagonAvatarView` — hexagonal avatars, NO circular avatars

---

## Localization

- **ALL** visible strings MUST use `NSLocalizedString("key", comment: "")`.
- **NO hardcoded English strings** in any View.
- When adding a new key, add it to **both** `en.lproj/Localizable.strings` and `ru.lproj/Localizable.strings` in the same commit.
- Nav titles: `.uppercased()` + `.tracking(4)` applied in `CTNavBar` — pass the raw localized string.
- Planned: Japanese locale (app name: **共創**, font: Hiragino). All strings must be ready.

---

## Glossary

We have our own terminology. Use it consistently in UI, code, and comments.

| ❌ Avoid | ✅ Use instead |
|---------|--------------|
| Account | Identity |
| Login / Sign in | Session |
| Register | Initialize |
| Device | Replica |
| Contact | Node |
| Profile | Identity |
| Server | Construct |
| Group | Cluster |
| Message thread | Stream |

---

## Architecture Notes

> **Before making any architectural decision**, search the wiki first:
> `ls /Users/maximeliseyev/Code/constrcut-docs/wiki/ | grep <topic>`
> The wiki has 500+ curated articles covering every component. AGENTS.md is operational rules;
> the wiki is the authoritative architecture documentation.

### Session lifecycle
12 stages: registration → key upload → prewarm → bundle fetch → init → send →
receive → decrypt → heal → END_SESSION → stream → Kyber OTPK.
All session operations are `@MainActor`. `usersInitializingSession: Set<String>` prevents parallel inits.

**INITIATOR vs RESPONDER paths** (critical — do not confuse):
- **INITIATOR**: fetch recipient bundle → X3DH → `init_session(bundle)` → send msgNum=0
- **RESPONDER**: receive msgNum=0 → fetch sender bundle → X3DH → `init_receiving_session(bundle, first_msg)` → decrypt

**Tie-break** (both sides init simultaneously): higher deviceId wins as INITIATOR.
WIN side: calls `initializeSessionProactively()` then `sendSessionPing()`.
LOSE side: wipes own session, waits for INITIATOR's ping.

**PQXDH** (post-quantum extension): Kyber-768 OTPK mixed into root key derivation.
Deferred PQ contribution applies to RK1 (post-first-ratchet) on both sides.
RESPONDER stores `pre_pq_root_key=RK1` before 2nd ratchet, re-derives sending chain after PQ.

**Session healing** (broken session recovery without END_SESSION):
Applicable only when `messageNumber == 0` (session init message decrypt fails).
`SessionHealingService.shared` — max 3 attempts, 24h TTL per contact.
On failure: falls through to END_SESSION → full re-init.
`RustHealingQueue` tracks attempts in Rust (persisted across restarts).

**Keychain accessibility of session keys:**
- `deviceSigningKey` / `deviceIdentityKey`: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- `deviceId`: `kSecAttrAccessibleAfterFirstUnlock`
- Session JSON: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Auth token: `kSecAttrAccessibleAfterFirstUnlock`

**Auth guard**: if `isAuthenticated == true` in memory, skip Keychain re-read.
Device keys are only deleted on gRPC UNAUTHENTICATED (16) or PERMISSION_DENIED (7) — never on network errors.

### Tab bar visibility
- `ChatsViewModel.isInChat: Bool` — set by `ChatsListView.onChange(of: navigationPath)`
- `ChatsViewModel.isInSettings: Bool` — set by `SettingsView.onChange(of: navigationPath)`
- `CTTabBar` renders only when both are `false`
- `SettingsView` must receive `.environment(chatsViewModel)` from `MainTabView`

### Tab rendering
All tab views coexist in a `ZStack` with `opacity(0/1)` + `allowsHitTesting`.
**iOS 26 fix**: tabs are gated by `@State private var visitedTabs: Set<Int>`.
Tab content is only inserted into the ZStack after the first visit (`if visitedTabs.contains(n)`).
This prevents iOS 26's `_ZStackLayout.sizeThatFits` from triggering `@FetchRequest.update()` on
invisible tabs during layout. Tab 0 (ChatsListView) is always in the set at init.
- `confirmationDialog` is blocked in ZStack hierarchy — use `.alert` instead
- State is preserved across tab switches (intended)

### construct-engine and EngineAdapter (CRITICAL for macOS/Desktop work)

**Full spec**: `constrcut-docs/raw/04_Client_Applications/specs/DESKTOP_ENGINE_REFACTORING_SPEC.md`
**Wiki article**: `constrcut-docs/wiki/EngineAdapter.md`

#### Two crypto paths — never confuse them

```
iOS (ConstructMessenger target)
└── CryptoManager / Services → ConstructCore.xcframework (UniFFI) → OrchestratorCore

macOS (Construct Desktop target)  ← TARGET ARCHITECTURE
└── EngineAdapter → construct-engine → [internal OrchestratorCore]
    ├── Transport (QUIC/H3)      ← already done
    ├── Auth / token management  ← already done
    ├── CryptoSession management ← TO DO (Phase 1)
    ├── Message encrypt/decrypt  ← TO DO (Phase 2)
    ├── Session healing          ← TO DO (Phase 4)
    └── PQ key management        ← TO DO (Phase 5)
```

**Current state (technical debt)**: macOS Desktop still has a *second* path — it compiles
the shared `CryptoManager.swift` / `MessageCryptoService.swift` / etc. which call
`OrchestratorCore` directly via `ConstructCore.xcframework`. This is wrong — the goal is to
route all crypto through `EngineAdapter` and remove `ConstructCore.xcframework` from the
Desktop target entirely (saves ~83 MB binary, eliminates dual-state OrchestratorCore).

#### iOS keeps direct UniFFI path (intentional)

iOS cannot run `construct-engine` with QUIC natively. The iOS direct path is production-stable.
Do NOT use `EngineAdapter` for crypto on iOS.

#### Compiler guard pattern for crypto code

When a service needs different crypto paths per platform:
```swift
#if os(macOS)
// Use engine for crypto
engineHandle.dispatch(.encryptMessage(...))
#else
// Use OrchestratorCore directly (iOS path)
cryptoManager.orchestratorCore?.encryptMessage(...)
#endif
```

#### Migration phases (do not skip ahead)

1. **Phase 1** — Session init: `InitSession`, `InitReceivingSession`, `EndSession` via engine
2. **Phase 2** — Message encrypt/decrypt via engine
3. **Phase 3** — Offline batch decrypt via engine
4. **Phase 4** — Session healing via engine
5. **Phase 5** — PQ key management via engine
6. **Phase 6** — Remove `ConstructCore.xcframework` + `construct_core.swift` from Desktop target

Before implementing any macOS-only crypto feature, check which phase it belongs to.
Do not implement a later-phase feature before earlier phases are done.

### UniFFI bindings
`construct_core.swift` is auto-generated — **never edit it manually**.
Regenerate with: `./generate_swift_bindings.sh`
`construct_core.swift` is compiled for **iOS only** — it must not be compiled for macOS once
Phase 6 is complete. Wrap any new UniFFI call in `#if os(iOS)` if it has no engine equivalent yet.

### gRPC
Generated protobuf files in `Networking/gRPC/Generated/` — do not edit manually.
Regenerate with: `./generate_grpc_swift.sh`

---

## Code Conventions

- Use `@Observable` for ViewModels (not `ObservableObject`)
- `@MainActor` on all ViewModels and services that touch UI state
- `#if DEBUG` / `#if os(iOS)` guards where appropriate
- No inline magic numbers — use `CT.*` tokens or named constants
- Comment only non-obvious logic; do not comment self-explanatory code
- Debug-only UI: orange color, `#if DEBUG` blocks, auto-visible in debug builds

---

## Binary Data Pipeline (CRITICAL — no redundant encodings)

Construct uses a fully binary data pipeline. Violating this rule introduces unnecessary
CPU cost, allocation pressure, and potential encoding bugs at every message.

### Rules

1. **No base64 in application logic.** Base64 is allowed ONLY at true text-transport
   boundaries: QR codes, deep links/URLs, `mailto:` params. It is NEVER acceptable
   inside message processing, session management, or storage.

2. **No JSON for binary payloads.** Keys, ciphertexts, sealed boxes, and wire payloads
   are `Data` / `[UInt8]` end-to-end. `JSONSerialization` / `Codable` must not see raw
   crypto bytes — use protobuf fields or CFE binary for that.

3. **UniFFI boundary uses `Data` / `[UInt8]`.** All Swift ↔ Rust FFI calls pass binary
   data as `Data` (Swift) or `[UInt8]` (UniFFI-generated). Never stringify before
   crossing the boundary.

4. **CFE binary format for session state.** Session JSON-in-CFE (`CfeSessionJsonWrapperV1`)
   is a known technical debt item. New session fields go into the binary CFE layer.
   Do not add new JSON fields to the session serialization path.

5. **`Codable` `Data` fields are fine.** Swift's `JSONEncoder`/`JSONDecoder` transparently
   base64-encodes `Data` values in JSON — this is acceptable for UserDefaults persistence
   (e.g. `OutgoingWirePayloadStore`) because no explicit encode/decode step appears in
   application code. Never add manual `.base64EncodedString()` / `Data(base64Encoded:)`
   around values that are already typed as `Data`.

6. **`encryptedContent` in Core Data is `Binary Data`.** The attribute uses
   `allowsExternalBinaryDataStorage = YES`. Do not change it to String or add base64
   when reading/writing from `MessagePersistenceService`.

7. **`ChatMessage.content` is `Data`.** The in-memory protocol model carries raw sealed-box
   bytes. Control messages (END_SESSION, ping) use `Data()` (empty), never a string literal.

### Before adding any new crypto/messaging field, ask:
- Is it `Data` from source to destination?
- Does it cross the FFI boundary as `[UInt8]`?
- Does the proto field hold `bytes`, not `string`?
- Is there zero `base64EncodedString()` or `Data(base64Encoded:)` in the path?

If any answer is "no", fix the design before merging.

---

## User Identity Spaces (CRITICAL — two distinct ID formats)

There are two separate user identity formats in this codebase. **Never mix them.**

| Type | Swift | Format | Source | Correct use |
|------|-------|--------|--------|-------------|
| `ServerUserId` | `Utilities/UserIdentity.swift` | 36-char UUID with dashes `14f28d31-…` | Server-assigned at registration | All session addressing: `local_user_id`, `contact_id`, `conversation_id`, contact lists |
| `CryptoDeviceId` | `Utilities/UserIdentity.swift` | 32-char hex `6f5e37ac…` | `deriveDeviceId(identityPublicKey)` | Multi-device linking, QR codes ONLY |

### The AD bug (postmortem — fixed in commit that adds this section)

`CryptoManager.cryptoLocalUserId` previously returned `loadDeviceID()` (32-hex CryptoDeviceId)
instead of `_cachedUserId` (36-char ServerUserId). The Double Ratchet AD is:

```
ENCRYPT: AD_VERSION || local_user_id || contact_id || …
DECRYPT: AD_VERSION || contact_id   || local_user_id || …
```

INITIATOR stored `local_user_id = "6f5e37ac…"` (32 hex).
RESPONDER stored `contact_id    = "14f28d31-…"` (36 UUID).
These never matched → permanent AEAD failure on every session, 100% reproducible.

**Invariant to maintain**: Everything passed to the Rust session layer (`init_session`,
`init_receiving_session`, `set_local_user_id`) MUST be a `ServerUserId`. The Rust
`debug_assert!` guards in `new_initiator_session` / `new_responder_session` catch this
in test builds. The `UserIdentity.swift` types make the distinction compiler-visible.

---

## Commits

Follow [Conventional Commits](https://www.conventionalcommits.org/):
```
feat(scope): short description
fix(scope): short description
refactor(scope): short description
chore(scope): short description
```

---

## Testing

```bash
# Unit + integration tests
xcodebuild test -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'
```

Key test files:
- `ConstructMessengerTests/` — unit tests
- `CryptoWireIntegrationTests.swift` — E2EE crypto integration tests

---

## Documentation

All project documentation: `~/Documents/Konstruct` (Obsidian vault)
Rules for writing documentation: `~/Documents/Konstruct/README.md`

### Key documents for new developers

| Topic | File |
|-------|------|
| Cross-platform protocol spec | `04_Client_Applications/specs/construct-protocol-v2-spec.md` |
| iOS client integration guide | `04_Client_Applications/CLIENT_SDK_SPEC.md` |
| **Android onboarding** | `04_Client_Applications/android/ANDROID_ONBOARDING.md` |
| Session flow (X3DH + DR) | `04_Client_Applications/session-flow.md` |
| Session persistence | `04_Client_Applications/session-persistence.md` |
| Account recovery (BIP39) | `04_Client_Applications/ACCOUNT_RECOVERY_CLIENT_SPEC.md` |
| Calls / WebRTC signaling | `04_Client_Applications/specs/CALLS_CLIENT_SPEC.md` |
| ICE relay fallback (RU) | `04_Client_Applications/specs/ICE_RELAY_FALLBACK_CLIENT_SPEC.md` |
| Multi-device support | `04_Client_Applications/specs/MULTI_DEVICE_CLIENT_SPEC.md` |
| FFI binary format (CFE) | `04_Client_Applications/construct-ffi-binary-format.md` |
| Security architecture | `06_Security/` |

### Documentation conventions
- Session implementation notes go in `08_Testing_and_Process/SESSION_YYYY-MM-DD.md`
- iOS bug fixes go in `04_Client_Applications/ios/fixes/`
- New specs go in `04_Client_Applications/specs/`
- All spec documents must have a **Version**, **Status**, and **Platform** header

---

## Shared Construct Docs Workflow

These instructions apply to GitHub Copilot, Codex, OpenCode, and similar coding agents.

### Shared knowledge base

- Use `/Users/maximeliseyev/Code/constrcut-docs` as the shared Construct documentation vault.
- Treat `/Users/maximeliseyev/Code/constrcut-docs/raw` as the source corpus. Do not rewrite, normalize, or reorganize files there unless the task explicitly targets raw-doc curation.
- Treat `/Users/maximeliseyev/Code/constrcut-docs/wiki` as the canonical curated knowledge base.
- Treat `/Users/maximeliseyev/Code/constrcut-docs/wiki/.drafts` as reserved for the `obsidian-llm-wiki-local` draft-review workflow. Do not write there manually unless the task explicitly involves `olw`.

### Where to save durable reasoning

**The goal**: any reasoning that informed a code change must survive beyond the chat session.
Conclusions, trade-offs, and "why we didn't do X" must be written down — not left in chat history.

**After any session involving architectural changes, design decisions, API changes, data format
changes, bug root-cause analysis, or non-obvious implementation choices:**

1. **Always** create or update a session note at
   `wiki/sessions/YYYY-MM-DD-<topic>.md`.
2. **Always** fill in `# Why` — the reasoning that drove the decision, including considered
   alternatives and why they were rejected. This is the most important section.
3. If the decision will constrain future work across sessions or the same question is likely
   to recur, also create a `wiki/decisions/<topic>.md` entry.
4. Before creating a new note, search for an existing relevant note and extend it.

Do not skip session notes for "small" changes — if the decision required non-trivial reasoning,
it belongs in the wiki. Future agents (and the developer) should never need to re-derive it.

### Session note template

Required sections (fill all of them):

1. `# Context` — what problem prompted this work
2. `# What Changed` — concrete file/API/behaviour changes
3. `# Why` — **the reasoning**: why this approach, what alternatives were considered, why rejected
4. `# Intended Outcome` — what success looks like; what should be true after this change
5. `# Decisions` — discrete decisions made, each as a one-liner fact
6. `# Open Questions` — known unknowns, follow-up work, things that were deferred

### Operational logging

- Append a one-line entry to `/Users/maximeliseyev/Code/constrcut-docs/wiki/log.md` whenever
  a session note or decision note is created/updated. Format: `[YYYY-MM-DD HH:MM] <verb> | <topic>`.
- Keep detailed rationale out of `log.md` — it belongs in the session/decision note.
