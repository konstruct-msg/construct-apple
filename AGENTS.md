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

All UI must follow the Construct Terminal (CT) design system.

### Tokens
- Colors: `Color.CT.bg`, `Color.CT.text`, `Color.CT.accent`, `Color.CT.danger`, `Color.CT.noise`, `Color.CT.textDim`
- Fonts: `CTFont.regular(size)`, `CTFont.bold(size)` — always JetBrains Mono
- Symbols: `CTSymbol.back`, `CTSymbol.forward`, `CTSymbol.close`, etc. (ASCII, no SF Symbols)

### Rules
- **NO SF Symbols** anywhere in app UI. Exceptions: system context menus, FaceID/TouchID prompts.
- **NO rounded corners** — `cornerRadius > 0` is forbidden in new code. Use `Rectangle()`.
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

### UniFFI bindings
`construct_core.swift` is auto-generated — **never edit it manually**.
Regenerate with: `./generate_swift_bindings.sh`

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
