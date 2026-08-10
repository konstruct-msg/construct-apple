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
├── scripts/two_sims.sh          # Two-simulator E2E stand (see below)
├── ConstructCore.xcframework/      # Built Rust crypto core + VEIL (NOT in git)
├── ConstructTransport.xcframework/ # Built Rust transport (NOT in git)
└── AGENTS.md                    # This file
```

Sibling repos: `~/Code/construct-core` (crypto), `~/Code/construct-transport` (QUIC/H3/gRPC),
`~/Code/construct-veil` (obfuscation proxy), `~/Code/construct-docs` (docs vault).

## Build

**iOS docs index**: `~/Code/construct-docs/client/ios/README.md`  
**Full guide (first build, target flags, gotchas)**: `~/Code/construct-docs/client/ios/BUILD_GUIDE.md`  
**UniFFI (current)**: `~/Code/construct-docs/client/ios/UNIFFI_GUIDE.md`

```bash
./build_crypto_lib.sh --all      # first build: ConstructCore.xcframework (iOS+sim+mac)
./build_transport_lib.sh         # first build: ConstructTransport.xcframework
./build_crypto_lib.sh --ios      # quick rebuild after Rust changes (~45s)

xcodebuild -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 17' build   # or `test`
```

**Never pin `OS=` in a destination.** Simulator runtimes are replaced with every Xcode
upgrade; a pinned one stops resolving and the failure reads like a project problem. This line
said `iPhone 16,OS=18.6` for months after that runtime was gone. Same for device names —
check `xcrun simctl list devices available` rather than trusting this example.

The `*.xcframework` binaries are NOT in git — after a fresh clone they must be built before
Xcode can compile the app.

## Two-simulator E2E stand

`scripts/two_sims.sh` runs the app on two dedicated simulators (`Construct-A` iPhone 17 Pro,
`Construct-B` iPhone 17) for send/receive scenarios that cannot exist on a single device.

```bash
./scripts/two_sims.sh run     # up + build + install + launch on both
./scripts/two_sims.sh pair a  # invite from A's pasteboard → openurl on B
./scripts/two_sims.sh env     # UDID_A / UDID_B / BUNDLE_ID for UI-automation tools
./scripts/two_sims.sh reset   # erase both → clean onboarding
./scripts/two_sims.sh shot    # screenshots → logs/two_sims/ (gitignored)
```

- **Pairing goes through the pasteboard, never the QR.** A simulator has no camera, so
  the scan path is undrivable. Settings ▸ COPY CONTACT LINK carries the same invite;
  `simctl pbpaste` reads it and `pair` hands it to the other sim. That command rewrites
  the copied HTTPS share link to the `konstruct://` scheme on purpose — the HTTPS form is
  a universal link and needs an apple-app-site-association fetch, so a simulator opens it
  in Safari instead of the app. Note simulator pasteboards auto-sync with the host, so the
  host clipboard bleeds in; `pair` rejects a buffer that holds no invite rather than
  guessing.

- **Two simulators already are two accounts** — separate container, Keychain and Core Data per
  sim. Do NOT add test-account launch arguments or environment flags to the app to distinguish
  them: the app reads no launch args today (`ProcessInfo` use is Preview detection only), and a
  test-only branch in production code is a worse price than one `reset`.
- **Typing goes through the simulator's active keyboard, so verify what landed.** UI automation
  sends HID key codes: under a Russian layout `alice` arrives as `фдш`, and the failure looks
  like a broken app. `up` forces `en_US`, but iOS restores the previous input source on app
  relaunch, so always read the field back. A first burst into an empty field also loses
  everything after the first character — type with `replaceExisting`, and expect to repeat it.
- **The stand is a happy-path UI harness, not a protocol test bed.** APNs push, VoIP + CallKit
  audio, background decrypt, and anything driven by network conditions (session healing, offline
  delivery, stream replay) do not reproduce faithfully on a simulator. Those belong in
  `ConstructMessengerTests` against a real server — a green two-sim run says nothing about them.
- Drive the UI through accessibility identifiers, not screenshot matching: a11y-tree reads are
  cheap and stable, pixel comparison is neither. New UI on a happy path gets an
  `accessibilityIdentifier`, and the string comes from `Utilities/AccessibilityIdentifiers.swift`
  (`A11y.*`) — never a literal at the call site. The consumer is outside this repo, so a rename
  breaks a scenario that still compiles.
- Rows and messages are addressed by id (`A11y.Chats.row(chat.id)`, `A11y.Chat.message(id)`),
  never by position — the list reorders on every incoming message.
- `A11y.Chat.messageStatus` encodes the delivery status **in the identifier**
  (`chat.message.<id>.status.delivered`). The status icons are bare SF Symbols with no label,
  and identifiers are neither localized nor user-visible — which makes them the right channel
  for machine-readable state, with no invented user-facing string.

Three SwiftUI accessibility facts this cost a live run to learn — none of them fail loudly:

- **An identifier on a container overwrites its descendants'.** `chat.message.<id>` was applied
  to the whole bubble row, so it stamped the delivery-status icon too and
  `.status.delivered` never existed. Scope an identifier to the leaf it names, never to a row
  that also holds independently-addressed children.
- **An unlabeled `Image` is dropped from the accessibility tree, identifier and all.** The
  status icons carried an identifier for a whole session and matched nothing. The
  `accessibilityLabel` is what makes the element exist — it is a prerequisite for the
  identifier, not a nicety. (It is also the only reason VoiceOver can read delivery state.)
- **`snapshot_ui` does not print elements whose action is `none`.** The status icon is neither
  tappable nor text, so it is invisible in a snapshot even when present. Assert it with
  `wait_for_ui` on an `identifier` selector; absence from a snapshot proves nothing.

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
- **A field left out on purpose at a boundary MUST say so in a comment.** Rebuilding a value
  across a boundary (unseal, FFI, wire→model) means listing fields, and in a list of twenty an
  omission that was deliberate is indistinguishable from one that was forgotten. This is not
  style: `pqMessageEpoch` and `pqRatchetField` were dropped at the unseal boundary and nobody
  could see it, precisely because the neighbouring deliberate omission (`sealedInnerData`) *was*
  commented and these two were not. Better still, give the boundary a name
  (`ChatMessage.resolvingSealedSender(_:currentUserId:)`) so it is an object a test can reach
  rather than an argument list inside a 200-line method.
- **A producer with no consumer is a defect, not dead weight.** If you add a send, a signal, or an
  action, the reader must exist in the same change — or the sender must be removed. An unconsumed
  message still costs a ratchet advance, and it surfaces somewhere: `__session_reset_notify__`
  shipped in April 2026 with no reader and spent four months writing itself into the transcript as
  a visible bubble on multi-device accounts. Same rule for the reverse:
  a handler that no producer reaches is either wired up or deleted.

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

## Sealed Sender Type Authority (CRITICAL — two representations, one authoritative)

| Layer | Field | Authoritative after unseal? |
|------|--------|------------------------------|
| Outer envelope (pre-unseal) | `messageType` / outer `content_type` | **No** — sealed path stamps these generic on purpose |
| `SealedInner` (post-unseal) | `contentType: UInt8` | **Yes** — sole routing input |

**Invariant**: any routing decision on a sealed delivery MUST read the post-unseal
`contentType` (via `ContentTypeRouting.kind(for:)` / `ChatMessage.isEndSession` etc.).
Never branch on the outer `messageType` string after `resolveSender`. Same shape of
defect as the two ID spaces: two parallel representations, silent disagreement, no
type enforcing agreement. Full remediation:
`~/Code/construct-docs/client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md`.

## Testing

**Full rationale + worked examples**: `~/Code/construct-docs/decisions/testing-by-pure-decision.md`

The target is **not a coverage number**. Coverage counts lines executed, not claims checked, and
this repo has paid for the difference: `SessionQueueWiringTests` passed for five weeks asserting
nothing after a production guard began returning early — it read all-zeros and confirmed them.
**A test that cannot fail is worse than no test**: it occupies the place where someone would
otherwise have looked.

### The method

1. **Extract the decision.** Take the branch out of the procedure and make it a free function or
   `static` over scalars — no network, no Core Data, no CallKit, no `Date()` (inject time). If a
   decision cannot be reached from a test, that is a design defect, not a testing gap: `"should we
   apply this SESSION_RESET_INIT"` was untestable as a chain of `if let` inside a `@MainActor`
   singleton, and testable the moment it became `remoteOfferDisposition(isIncomingCall:hasAnswered:)`.
   Nearly every fix in this codebase has that shape — `shouldTearDownAfterEndSession`,
   `heldReplayDisposition`, `shouldRecoverStrandedViewport`, `isResetInitSuperseded`.

2. **Name the test after the incident, not the function.** `testSessionReestablishedDuringFlight_IsKept`,
   not `testShouldTearDown_returnsFalse`. Put the device log in the comment — the timestamps, the
   real numbers. A test whose reason for existing is only in a commit message loses it.

3. **Pin the cases that must NOT fire.** Every corrective rule can misfire, and the misfire is
   usually worse than the bug: a scroll recovery that yanks a reader back mid-message, a coalescer
   that drops a live re-init. Assert those explicitly.

4. **Verify by mutation — one mutation per run.** Break the production line deliberately, run the
   suite, and confirm the *named* test goes red. A mutation nothing kills means the test is
   decorative. **Check the build compiled first**: a build failure looks exactly like "no test
   failed", and that reassuring shape once nearly had correct tests rewritten.
   Restore from a `.bak` copy in the scratchpad, never `git checkout` (it takes unrelated work
   with it).

5. **Say what is not covered, in the code.** When wiring cannot be reached from a test, write that
   down at the call site — `sessionEpoch(for:)` is not proven to be connected to a real session by
   any test, and an always-`nil` epoch would make every guard pass silently. State it and name the
   log line that would answer it on device. An honest gap is worth more than a test that fakes it.

### Counting

`xcodebuild … test` prints a line per test; a retried clone prints some twice. Count **unique**:

```bash
xcodebuild -scheme ConstructMessenger -destination 'platform=iOS Simulator,name=iPhone 17' test \
  2>&1 | grep -oiE "^Test case '[^']+' passed" | sort -u | wc -l
```

**`-i` is not optional.** The two run modes print different text: parallel clones print
`Test case 'FooTests.testBar()' passed`, a `-parallel-testing-enabled NO` run prints
`Test Case '-[ConstructMessengerTests.FooTests testBar]' passed`. Case-sensitively this command
answers **0** for a run where everything passed — the same shape of lie as a build failure reading
like "no test failed".

### Running one class (mutation verification)

`scripts/test_run.sh ConstructMessengerTests/FooTests` — scoped, no simulator clones (~40s vs
~65s), separates "build did not complete" from "no test failed", and if the build wedges it writes
a diagnosis (last command, disk, process list, `sample` of the build service) instead of dying
silently at your timeout. Six such wedges between 2026-08-08 and 2026-08-10 cost two mutations
their verification; the cause is not yet known, so the script captures evidence for the next one.

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
