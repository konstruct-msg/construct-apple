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

### Tab bar visibility
- `ChatsViewModel.isInChat: Bool` — set by `ChatsListView.onChange(of: navigationPath)`
- `ChatsViewModel.isInSettings: Bool` — set by `SettingsView.onChange(of: navigationPath)`
- `CTTabBar` renders only when both are `false`
- `SettingsView` must receive `.environment(chatsViewModel)` from `MainTabView`

### Tab rendering
All tab views coexist in a `ZStack` with `opacity(0/1)` + `allowsHitTesting`. This means:
- `confirmationDialog` is blocked in this hierarchy — use `.alert` instead
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
