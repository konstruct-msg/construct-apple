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
├── ConstructCore.xcframework/   # Built Rust crypto core (NOT in git — see Build Commands)
├── ConstructEngine.xcframework/ # Built Rust transport engine (NOT in git — see Build Commands)
├── build_crypto_lib.sh          # Script to rebuild construct-core
├── construct_engine.swift       # UniFFI auto-generated bindings — DO NOT EDIT
└── AGENTS.md                    # This file
```

The Rust core lives at: `~/Code/construct-core`
The Rust engine lives at: `~/Code/construct-engine`
The Rust VEIL proxy (obfuscation layer) lives at: `~/Code/construct-veil`

---

## Token Efficiency Tools

These tools compress project data for LLM consumption. **Always use them before
reading files, analyzing build output, or exploring the codebase.** They never
modify originals — all output goes to stdout.

### Decision flow: which tool when?

```
Need to read a source file?
  ├─ Full understanding needed  → ./tools/squash_file file.swift
  ├─ Just the API surface        → ./tools/squash_file --outline file.swift
  └─ Only imports + top types    → ./tools/squash_file --imports file.swift

Ran a build and got output?
  └─ Always filter first:        xcodebuild ... 2>&1 | ./tools/squash_build

Have logs to analyze?
  ├─ From a file:                ./tools/squash_logs.py app.log
  └─ From clipboard:             ./tools/squash_logs.py --clip --copy

Exploring an unfamiliar area?
  └─ Start here:                 ./tools/project_index
```

### Tool reference

**squash_file** — strip comments, imports, blanks, MARK annotations from source.
```bash
./tools/squash_file ConstructMessenger/Networking/gRPC/ICE/ConnectionLoop.swift
./tools/squash_file --outline ConstructMessenger/Security/CryptoManager.swift
./tools/squash_file --imports ConstructMessenger/ViewModels/ChatViewModel.swift
# Also works from stdin:
cat file.swift | ./tools/squash_file
```

**squash_build** — keep only errors + first warning per file from xcodebuild.
```bash
xcodebuild -scheme ConstructMessenger -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build 2>&1 | ./tools/squash_build
```

**squash_logs.py** — compress logs: relative timestamps, emoji→markers, dedup, bucket heartbeats.
```bash
./tools/squash_logs.py ~/Downloads/construct-logs.txt
./tools/squash_logs.py --clip --copy
cat *.log | ./tools/squash_logs.py
```

**project_index** — one-line-per-file map of the entire project.
```bash
./tools/project_index
./tools/project_index ~/Code/construct-server   # index another repo
```

### Expected workflow

```bash
# Before reading ANY file — strip noise
./tools/squash_file path/to/File.swift

# Before exploring a new directory — get the map
./tools/project_index

# After every build attempt — filter output
xcodebuild ... 2>&1 | ./tools/squash_build

# Before pasting logs into context
./tools/squash_logs.py app.log
```

### Token impact
| Tool | When to use | Savings |
|------|------------|:------:|
| `squash_file` | Before reading ANY .swift/.rs/.kt file | −36% |
| `squash_file --outline` | When you only need the API surface | −90% |
| `squash_build` | After every `xcodebuild` command | −95% |
| `squash_logs.py` | Before analyzing any log output | −30% |
| `project_index` | First step when exploring unfamiliar code | −100% vs grep |

## Build Commands

### Prerequisites

All three Rust crates must be cloned alongside this repo:
```
~/Code/
├── construct-core/        # Cryptographic core (X3DH, Double Ratchet, Kyber, etc.)
├── construct-engine/      # QUIC/H3/gRPC transport engine
├── construct-veil/        # obfs4/WebTunnel obfuscation proxy (DPI evasion). Was construct-ice.
└── construct-messenger/   # This repo — iOS/macOS SwiftUI app
```

### First build

After a fresh clone, the `*.xcframework` directories are empty stubs.
You MUST build the Rust libraries before Xcode can compile the app.

```bash
# 1. Build construct-core (crypto) — produces ConstructCore.xcframework
cd ~/Code/construct-messenger
./build_crypto_lib.sh --all          # iOS + Simulator + macOS in one go

# 2. Build construct-engine (transport) — produces ConstructEngine.xcframework
cd ~/Code/construct-engine
./build_engine.sh

# 3. Build the iOS app (simulator)
cd ~/Code/construct-messenger
xcodebuild -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build
```

### Rebuilding after Rust changes

```bash
# Rebuild crypto (iOS device only — fastest iteration, ~45s)
./build_crypto_lib.sh --ios

# Rebuild crypto for everything iOS-side (device + simulator)
./build_crypto_lib.sh --ios --sim

# Rebuild engine (all platforms)
cd ~/Code/construct-engine && ./build_engine.sh

# Clean Xcode build folder before next build
# Xcode: ⌘⇧K  or  Product → Clean Build Folder
```

### Build target flags

Target flags **accumulate** — you can combine them in one invocation.
Without any flag the script defaults to `--ios`.

```bash
./build_crypto_lib.sh --ios        # iOS device only (arm64)
./build_crypto_lib.sh --sim        # Simulator only (arm64 + x86_64 fat)
./build_crypto_lib.sh --mac        # macOS native (arm64)
./build_crypto_lib.sh --all        # All three at once (--ios --sim --mac)
./build_crypto_lib.sh --dist       # macOS universal fat (arm64 + x86_64) for DMG
./build_crypto_lib.sh --clean      # cargo clean before build (combine with target flags)
./build_crypto_lib.sh --debug      # Debug profile instead of release (combine with target flags)
```

After the build, the script updates all three slices of `ConstructCore.xcframework`:
- `ios-arm64/libconstruct_core.a`
- `ios-arm64_x86_64-simulator/libconstruct_core_sim.a`
- `macos-arm64/libconstruct_core_mac.a`

> **Note**: The xcframework binaries are NOT tracked in git.
> They must be rebuilt locally after cloning.
> In the future, they will be built in CI (GitHub Actions) and attached to releases.

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
- **SF Symbols** (`Image(systemName:)`): use for **all interactive controls** on both iOS and macOS —
  back/close buttons, action buttons, tab bar items, media controls, send, attach (`plus.circle`),
  mic, search, close (×). This rule applies to both platforms.
- **`CTSymbol.*` ASCII glyphs**: use for **structural / decorative elements only** —
  forward `[→]`, section headers (`> TITLE`), separators, status indicators, decorative symbols.
  Do **not** use `CTSymbol.back` (`[←]`) or `CTSymbol.attach` (`[+]`) — these are replaced by SF Symbols.
- Dividing line: *interactive tappable action?* → SF Symbol. *Terminal aesthetic chrome?* → CTSymbol.

**Platform-specific SF Symbol conventions (iOS is primary, macOS follows):**
- Back navigation: iOS → `chevron.backward.circle.fill` (size 22); macOS → `chevron.backward.circle` (size 18)
- **Modal / sheet close on macOS**: use `xmark.circle` (size 18) — NOT chevron. macOS users expect a close button in sheets. Pass `isModal: true` to `CTNavBar`.
- iOS modals: `chevron.backward.circle.fill` same as navigation (sheet dismiss via swipe is the primary affordance)
- Design code is shared: no `#if os(iOS)` / `#else` blocks for the same symbol concept — use `#if os(macOS)` only to swap to the macOS platform variant.

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
| ICE (obfuscation layer) | VEIL |
| obfs4/WebTunnel proxy | VEIL |

### VEIL vs WebRTC ICE — never confuse them

There are two "ICE"-named concepts in the codebase. They are completely
unrelated and must NOT be conflated:

| | What | Where it lives |
|---|---|---|
| **VEIL** | Our obfuscation layer (obfs4 + WebTunnel pluggable transports for DPI evasion). Renamed 2026-05-29 from "ICE". | `Networking/gRPC/VEIL/`, `VeilProxy*`, `veil_*` C FFI, `construct-veil` Rust crate |
| **WebRTC ICE** | Interactive Connectivity Establishment (industry-standard P2P NAT traversal for calls). Stays "ICE" — do not rename. | `Services/Calls/`, `IceCandidate`, `iceCandidate`, `iceFlushTask`, WebRTC.framework |

When writing new obfuscation/relay/proxy code, always use `Veil*` / `veil_*`.
When writing new call signaling code, use industry WebRTC `Ice*` names.
The `iceBridgeCert` field in `auth_service.pb.swift` is a legacy proto field
name for VEIL bridge cert (will be renamed when proto regenerates).

---

## Architecture Notes

> **Before making any architectural decision**, search the wiki first:
> `ls ~/Code/construct-docs/wiki/ | grep <topic>`
> The wiki has 500+ curated articles covering every component. AGENTS.md is operational rules;
> the wiki is the authoritative architecture documentation.
>
> **Before touching any file in `Networking/gRPC/ICE/`**, check pending decisions:
> `ls ~/Code/construct-docs/wiki/decisions/ | grep ice`
> In particular: `decisions/ice-connection-loop-complexity.md` — deferred refactor with trigger.

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

**Full spec**: `construct-docs/raw/04_Client_Applications/specs/DESKTOP_ENGINE_REFACTORING_SPEC.md`
**Wiki article**: `construct-docs/wiki/EngineAdapter.md`

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
   crossing the boundary. Two patterns to watch:
   - A UniFFI struct that exposes `String` fields holding base64 is a leak —
     declare the UDL field as `sequence<u8>` instead. (Historical example:
     `RegistrationBundleJson` returned base64 strings; replaced 2026-05-30 by
     `RegistrationBundleFields` with raw byte fields.)
   - `[UInt8](data)` / `Data(bytes)` Swift-side wrapping is the current
     idiomatic UniFFI cost. Acceptable, but minimise — don't double-wrap.

4. **CFE binary format for session state.** Sessions persist as CFE envelopes
   (`CfeSessionStateV1`) — 16-byte header + MessagePack payload via `rmp_serde`.
   The legacy `CfeSessionJsonWrapperV1` (JSON wrapped in a CFE envelope) was
   removed from production paths on 2026-05-30; it survives only in tests
   that exercise import backwards-compatibility. New session fields go into the
   binary CFE layer. Do not introduce JSON-bytes-into-Keychain anywhere on the
   crypto pipeline — every `Action::SaveSessionToSecureStore` data field must
   originate from `export_session_bytes_for` (CFE), never from
   `export_session_json_for`.

   Active paths producing the right CFE binary today:
   - `encrypt` / `decrypt` / `decrypt_wire_payload` follow-up save
   - `archive_session` snapshot
   - `maybe_apply_pq_contribution` post-Kyber save
   - `restore_latest_archive` round-trip

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

All project documentation: `~/Code/construct-docs` (Obsidian vault)
Rules for writing documentation: `~/Code/construct-docs/README.md`

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

### Division of labour — read this first

The wiki is maintained by a three-way workflow. **Do not overstep your role.**

| Role | Tool | Responsibility |
|------|------|----------------|
| **Coding agent** (you) | Copilot / Codex / OpenCode | Write code + drop raw session notes into `wiki/sessions/` and `wiki/decisions/`. That is all. |
| **Wiki pipeline** | `obsidian-llm-wiki-local` (olw) | Reads `raw/`, synthesizes concepts, creates/updates wiki articles, generates cross-links. Runs separately. |
| **Developer** | Human + Obsidian | Reviews wiki draft articles, approves or rejects with feedback. Curates `raw/`. |

**Your job is code.** olw handles article synthesis, concept extraction, and cross-referencing.
You do not need to write wiki articles, create `[[wikilinks]]`, or add YAML frontmatter.
Just write clear, factual session notes and let the pipeline do the rest.

### Shared knowledge base

- Vault: `~/Code/construct-docs`
- `raw/` — source corpus. Do **not** rewrite, normalize, or reorganize unless explicitly asked.
- `wiki/` — canonical curated knowledge base. **Read** from here before architectural work.
- `wiki/.drafts/` — **reserved for olw**. Never write here manually.
- `wiki/sessions/` — where coding agents write session notes.
- `wiki/decisions/` — where coding agents write long-lived decision records.

### Where to save durable reasoning

**The goal**: any reasoning that informed a code change must survive beyond the chat session.
Conclusions, trade-offs, and "why we didn't do X" must be written down — not left in chat history.

**After any session involving architectural changes, design decisions, API changes, data format
changes, bug root-cause analysis, or non-obvious implementation choices:**

1. **Always** create or update a session note at `wiki/sessions/YYYY-MM-DD-<topic>.md`.
2. **Always** fill in `# Why` — the reasoning that drove the decision, including considered
   alternatives and why they were rejected. This is the most important section.
3. If the decision will constrain future work across sessions or the same question is likely
   to recur, also create a `wiki/decisions/<topic>.md` entry.
4. Before creating a new note, search for an existing one and extend it instead of duplicating.

Do not skip session notes for "small" changes — if non-trivial reasoning was involved, it
belongs in the wiki. Future agents and the developer should never need to re-derive it.

### Session note format

Write plain markdown. No YAML frontmatter, no `[[wikilinks]]` — olw will add those.
Required sections (fill all of them):

1. `# Context` — what problem prompted this work
2. `# What Changed` — concrete file/API/behaviour changes
3. `# Why` — **the reasoning**: why this approach, what alternatives were considered, why rejected
4. `# Intended Outcome` — what success looks like after this change
5. `# Decisions` — discrete decisions, each as a one-liner fact
6. `# Open Questions` — known unknowns, deferred work

### Operational logging

- Append a one-line entry to `wiki/log.md` after creating/updating a session or decision note.
  Format: `[YYYY-MM-DD HH:MM] note | <topic>`
- Keep detailed rationale out of `log.md` — it belongs in the session/decision note.
