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
| Session lifecycle, keychain, crypto/transport path | `~/Code/construct-docs/client/ios/ARCHITECTURE_NOTES.md` · target machine: `~/Code/construct-docs/decisions/session-is-one-state-machine.md` |
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

**Affordance is native, identity is ours** — three layers, and the line is fixed
(`decisions/affordance-is-native-identity-is-ours.md`, staged plan
`client/ios/NATIVE_AFFORDANCE_MIGRATION.md`):

| Layer | Who decides the look |
|---|---|
| **Control and state** — buttons, toggles, navigation, selection, status, disclosure | the platform, always |
| **Structure and rhythm** — grid and density, hairlines, section headers, palette, dark default, identicon avatars (a circle — hexagons were dropped 2026-05-04), the monospace chrome | us; this is the identity |
| **Content** — message text (`CTFont.message`) | the reader |

The test: *does a person have to learn this app to know what it does?* If yes it is a control, and
it looks like the platform's control.

**No new ASCII control and no new ASCII status, anywhere** — including in feature work unrelated to
the migration. SF Symbols and native controls for anything interactive or stateful (`CTStatusBadge`,
`Toggle`, `chevron.*`); ASCII only as structure (`> TITLE` headers, the `>` system-message prefix,
separators, keycap hints, debug surfaces). Never regress a converted control back to ASCII. The
ASCII affordances still in the tree are enumerated debt, not the target state.

A surface that does not exist yet is built under this rule from the start — it is not written in the
old language and migrated later. If a token it needs is missing, the token lands first.

`client/ios/DESIGN_CONCEPT.md` §2.3 in the vault describes brackets as the affordance metaphor; that is
**history, superseded 2026-09-20**, and the file says so. Do not implement from it.

Tokens — source of truth `ConstructMessenger/Utilities/ConstructTheme.swift`:

| Kind | API |
|------|-----|
| Colors | `Color.CT.bg`, `.text`, `.textDim`, `.accent`, `.accentDim`, `.danger`, `.online` (status only), `.noise`, `.bgMsg`, `.outMsgBg`, `.outMsgText` |
| Fonts | Chrome: the roles `CTFont.title/headline/body/bodyEmphasis/secondary/caption/micro/badge`, or `CTFont.ui(size, weight:)` for a size outside them — JetBrains Mono, Dynamic Type via `relativeTo:`. `CTFont.mono(size)` for content that *is* machine output. `CTFont.message(size)` for message text: the one face the reader chooses, system by default. The pre-split `CTFont.regular/medium/bold` were removed 2026-10-06 |
| Radii / Shapes | `CTRadius` (`badge` 6 · `card` 8 · `control` 10 · `pill` 999) via `CTShape.*()` — no magic `cornerRadius: 16\|18\|22` |
| Layout | `CTLayout` (`edgePad` 12 · `controlHeight` 42 · `hitTarget` 44 · …) |
| Glass | `.glassCapsule()` — defaults to pill; do not pass 18/22 |

- Two surface languages, never mixed on one control: **form/card** (`CTRadius.card`, solid) vs
  **composer/glass** (`pill`, `.glassCapsule()`); `CTButton`/bubbles use `CTRadius.control`.
- **Message text is the one thing the reader picks the font for.** `CTFont.message` — bubbles and
  the composer that fills them — reads a preference, **system face by default** since
  2026-09-21. It stays a preference and nothing else gains one: a font choice read inside the
  chrome tokens would make the product configurable rather than designed. Note "always JetBrains
  Mono" was never true where it mattered — the family ships no CJK, so Japanese bubbles have
  always been a substituted face. `CTFont.message` also carries the size preference and
  `relativeTo: .body`.
- **The chrome is monospace and stays so.** It was the system face for one day (2026-09-20 → 21)
  and, seen on a device, the mono chrome was the identity worth keeping. `CTFont.ui` and
  `CTFont.mono` resolve to the same family today; the split is kept because it records *why* a
  site is monospace (this is a fingerprint) and is what lets the chrome move again without the
  fingerprints moving with it. Do not hand-roll `.system(...)` or `.monospaced` at a call site.
- **JetBrains Mono is bundled since 2026-09-21** — `ConstructMessenger/Fonts/` (four weights +
  `OFL.txt`), `UIAppFonts` in the iOS `Info.plist`, `ATSApplicationFontsPath` in the Desktop one.
  Before that the name was looked up and nothing answered: every build had rendered SF Mono under
  the JetBrains name, for eight months, with nothing to say so. The synchronized group flattens
  resources into the bundle root, so `UIAppFonts` lists bare file names — a `Fonts/` prefix is
  ignored silently. `ThemeTypographyTests` asserts the four PostScript names resolve at runtime.
- **Bars are the system's** (`decisions/navigation-bars-are-the-systems.md`, 2026-10-07):
  `.navigationTitle` + `inlineNavTitle()` and `.toolbar` items, each a symbol *and* a title. A
  sheet with a title or an action is wrapped at the presenting site in `.sheetNavigation()` (its
  own `NavigationStack` and a close item). Until then this file banned `NavigationStack` in sheets
  and prescribed `CTNavBar`; the ban's one recorded reason was the terminal look of the bar, which
  2026-09-20 withdrew, and on iPhone Duo only system bars stand vertically. `CTNavBar` and
  `hideSystemNavBar()` are retiring: no new call site. Our part of the bar is set once, app-wide —
  tint and title face — never per screen.
- Background always `Color.CT.bg` (`#090909`) via `.ctBackground()`.
- New UI must use tokens; when editing a file with a literal `8`/`10`/`18`, migrate that call site.
- Debug-only UI: `.orange`, `#if DEBUG`.
- Tab bar is the standard SwiftUI `TabView`; a conversation hides it with `.hidesTabBar()`
  (`Platform/PlatformNavBar.swift`). Until 2026-10-08 this said `.toolbar(.hidden, for: .tabBar)`,
  which brings the bar back only after the pop has finished — ~0.3 s of a list without its tab
  bar, measured on video; `hidesTabBar()` moves it into the transition.

**Xcode Previews run in the app target since 2026-10-01** — `InCallView`'s preview rendered on
Xcode 27 (JIT executor), with the scheme `ConstructMessenger` (Debug, `-Onone`). Until then this
paragraph said they could not: the preview process died at launch with `_objc_fatal: Attempt to
use unknown class` once WebRTC or WhisperKit loaded. Which change ended that is not established —
the same day WebRTC moved from stasel's package to webrtc-sdk (`Packages/WebRTC`), and the toolchain
was Xcode 27 — so if previews break again, check those two first. A preview needs the Debug
configuration: the `Construct Messenger Beta` scheme runs Beta, built `-O`, which Previews refuse.
A preview that fails with "ThunkContentMarker … invalidated" lost its file to an edit mid-build;
refresh it.

A separate previewable package is a recurring idea and was tried once. If you rebuild it, the
theme file is **shared, never copied** — the copy is what killed the last attempt. Read
`decisions/one-theme-file-shared-not-copied.md` first.

## Localization

- **All** visible strings use `NSLocalizedString("key", comment: "")` — no hardcoded English.
- New keys go to **every** locale — `en`, `ru`, `ja`, `fr`, `hy-AM` — in the same commit.
  The list is `OTHER_LOCALES` in `scripts/check_localization.sh`; a locale added to the app is
  added there in the same change, or nothing checks it (`hy-AM` went unchecked for a day and
  missed the next commit's keys). The script enforces parity, no duplicate keys, no key that resolves to
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
  in Japanese, `Կոնստրուկտ` in Armenian (case endings attach without a hyphen:
  `Կոնստրուկտը`) — a localized name is a transliteration, never a translation. The one deliberate
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

## The core decides, this app executes

**Before writing any session or crypto decision in Swift, open `~/Code/construct-core/src/construct_core.udl`.**
It is the list of what the core already does, and this app keeps rebuilding entries from it. Already
exported and already ignored at least once each: `derive_device_id`,
`get_all_session_contact_ids` (the devices we hold sessions with — half of any per-device plan),
`get_session_health`, both init paths, `remove_session`.

The test for where something belongs is not "which side has the data at hand" — the client always
has it at hand, which is how this rule keeps getting broken. It is:

| Question | Answer |
|---|---|
| Must two clients compute this **identically** for a message to be readable? | **core** |
| Does it read or write ratchet/session state? | **core** |
| Is it "which sessions does this operation touch"? | **core** — a plan is protocol |
| Is it the **lifecycle phase** of a session (open / heal / tear down / retry)? | **core** — a machine is protocol; do not add a coordinator dictionary. `decisions/session-is-one-state-machine.md` |
| Is it a mapping to a server-assigned id (account UUID, mailbox, chat row)? | this app |
| Is it network, Core Data, Keychain, UI? | this app |

A decision reimplemented here does not fail loudly when it diverges from the core or from
`construct-tui` — it drops a copy, and the message simply does not appear. That is why the rule is
"ask the core", not "match the core": a comment promising that two implementations agree is a
comment saying one of them should have been a call to the other
(`decisions/one-meaning-two-carriers.md`).

**The account space stops at the seam.** The core does not know `ServerUserId` — deliberately.
So the `account → devices` directory is this app's job, and that is the *only* part of a per-device
plan that belongs here: translate the account to a set of `CryptoDeviceId`, hand the **set** to the
core, and let the core decide which of them the operation touches. Building the plan here because we
did the translation here is exactly the inversion that produced `MultiDeviceSendCoordinator`.

Current known exceptions, with their destination — do not treat them as settled placements:
the account-keyed `sessionPhases` and the per-scope init locks are the leftover of a coordinator
that still decides; they belong in the core machine (`decisions/session-is-one-state-machine.md`).
The queue of messages waiting for a session moved there on 2026-09-26
— this app keeps envelopes and must not grow a second queue beside the core's
(`decisions/first-contact-queue-keyed-by-claimed-device.md`). **Receiving opens fetch nothing**
since 2026-09-27: a first message opens with the key its sender certificate names, once the core
has checked the server's signature. This app hands the certificate over with the message
(`ChatMessage.senderCertificate`) and the server keys before each open; it never fetches the
sender's bundle to receive, and never walks the sender's devices
(`decisions/first-message-opens-without-the-server.md`).
`PeerDevice` is a legitimate local store but is not the authority on a peer's device set. See
`decisions/a-peer-is-a-set-of-devices.md`.

**Everything below the seam takes a device id.** `encryptMessage`, `hasSession`, `archiveSession`,
`restoreSession`, `getSessionHealth`, `sessionEpoch`, the background decrypt — each names one
ratchet, and `SessionAddressing.asDevice(_:)` checks that rather than resolving, logging an error
with the caller's name when it is handed an account. A caller holding an account expands it with
`deviceIds(ofPeer:)` and acts on the whole set, or asks one of the folds
(`hasSessionWithAnyDevice(ofPeer:)` and friends). `pinnedDevice(ofPeer:)` — the single device a
peer's one pinned key names — is the offline answer and nothing else; it may not appear under the
crypto layer, and `CryptoIdentitySpaceTests` fails if it does, or if anyone takes `.first` of a
device set.

## Architecture invariants

**A change on the delivery or crypto path answers three questions before it lands**, in the
commit message or the session note — not "this is safe", but the answers:

1. What does the server (or any relay) learn that it did not learn before?
2. What can a party — server, sender, a sibling device — withhold or substitute that it could
   not before?
3. Which trust boundary moves, and in which direction?

"An improvement must not cost security" is what everyone already nods at, and it has no
content until it is a question with an answer. The questions are the content. A change whose
honest answer to 1 or 2 is "something" is not merged on the strength of the improvement; it is
a design decision and goes through `decisions/`. Example of the rule applied: the 2026-09-21
mailbox merge filter (`construct-server` PR #53) — learns nothing new (the field was already
read at dispatch), a sender can misdirect only its own envelopes and only as the cutover would
anyway, and the boundary moved inward (ciphertext sealed to one device stops reaching its
sibling). Asked before the merge, not after.

Before any architectural decision, search the vault:
`grep -ril <topic> ~/Code/construct-docs/{architecture,backend,client,cryptocore,security,decisions}`.
Before touching `Networking/gRPC/VEIL/` or `Services/Calls/`, read
`decisions/ice-connection-loop-complexity.md` — it predates the rename below and covers both.

- **INITIATOR and RESPONDER init paths are distinct** (`init_session` vs
  `open_receiving`). **A session renews by sending** since 2026-09-27: any message carrying the
  handshake header (ML-KEM ciphertext) opens a new state beside the one held, and the core keeps
  previous states and promotes the one that decrypts. There is no SESSION_RESET_INIT,
  `session_ready`, ping, confirm window, tie-break or heal — do not rebuild any of them here
  (`decisions/sessions-renew-by-sending.md`).
- **There is no END_SESSION** since 2026-09-28. A message nothing reads is answered by the core
  with a DECRYPTION_ERROR (content type 28) naming the state it was written on; the writer's core
  retires that state only if it is current, and resends the named message once. Manual reset,
  chat and contact deletion and logout are **local** — nothing is sent. Do not add a teardown
  message, a cooldown, a stale-by-timestamp check or an "announce the reset" path: a message that
  names no state is the thing this replaced.
- **Keychain**: crypto state that must survive a background/locked push decrypt uses
  `kSecAttrAccessibleAfterFirstUnlock*` (`KeychainManager.cryptoKeyAccessible`), never
  `WhenUnlocked*` — otherwise silent session desync and END_SESSION teardown of healthy sessions.
- **Ask the core for the operation, never for the key.** Signing with the device key, opening a
  box sealed to it, device-copy tags and the MLS signer are `OrchestratorCore` calls
  (`signWithDeviceKey`, `openSealedToDevice`, `deviceCopyTag*`, `newMlsStore`/`importMlsStore`)
  since 2026-09-29. Before that the secret was read out (`getSigningKeyBytes`, the Keychain's
  `deviceIdentityKey` copy) on every sealed message and every send, and this file carried a second
  CryptoKit implementation of the sealed box. The Keychain holds the device keys once, in the
  key record (`crypto_private_keys`) the core loads from; the raw copies are deleted at launch.
  The history-file channel key and the social-recovery bundle are made in the core too.
- **History transfer is the core's protocol; this app moves bytes.** CTH1 framing, record order,
  the chunk cipher, CTT1 v2 and CTHF frames and every check on them are
  `construct-core/src/history/` since 2026-09-29 (`HistorySender` / `HistoryReceiver`). The app reads what
  `need()` asks, feeds it, fetches the directory keys at `AwaitKeys`, decodes released records
  into Core Data and writes media pieces to disk (`HistoryCoreStream`). Until then it was ~1 500
  lines of Swift shared with nothing else, which Android would have had to write a second time.
  `HistoryChannelTests` fails on a CryptoKit import on this path.
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
object a test can reach rather than an argument list inside a 200-line method. Best, do not list:
since 2026-09-29 that boundary copies the message and assigns the few fields it replaces, and the
parsed header fields are gone from `ChatMessage` altogether — it keeps `rawPayload` and the core's
`wire_summary` of it, so there is no copy of the payload to drop.

**A producer with no consumer is a defect, not dead weight.** If you add a send, a signal or an
action, the reader must exist in the same change — or the sender must be removed. An unconsumed
message still costs a ratchet advance, and it surfaces somewhere: `__session_reset_notify__`
shipped in April 2026 with no reader and spent four months writing itself into the transcript as a
visible bubble on multi-device accounts. The reverse holds too: a handler no producer reaches is
either wired up or deleted.

## Binary data pipeline (no redundant encodings)

1. **No base64 in application logic** — only at true text-transport boundaries (QR, deep links,
   `mailto:`). Never in message processing, session management or storage.
2. **No JSON for binary payloads** — keys, ciphertexts and wire payloads are `Data` end to end;
   use protobuf `bytes` or CFE binary.
3. **The UniFFI boundary passes `Data`** — UDL byte fields and arguments are `bytes`, never
   `sequence<u8>` and never `String`. Both are `Vec<u8>` in Rust; the bindings are not alike:
   `bytes` is `Data`, one block copy, while `sequence<u8>` is `[UInt8]` copied one byte per call
   (and `List<UByte>`, an object per byte, on Android). This rule prescribed `sequence<u8>` until
   2026-09-29 — it meant "not base64", and 195 fields were the slow kind. The core's
   `construct-core/tests/udl_bytes_test.rs` fails on a new one. A value from the core is already `Data`: do not
   wrap it in `Data(…)`, which copies it again.
4. **Session state persists as CFE envelopes** — every `Action::SaveSessionToSecureStore` data
   field originates from `export_session_bytes_for`, never `export_session_json_for`.
5. `Codable` `Data` fields (implicit base64 in JSONEncoder) are fine for UserDefaults persistence;
   never add manual `.base64EncodedString()` / `Data(base64Encoded:)` around a typed `Data`.
6. Core Data `encryptedContent` is `Binary Data` (external storage); `ChatMessage.content` is
   `Data` — control messages use `Data()`, never a string literal.

Before adding any crypto or messaging field: is it `Data` source-to-destination, `bytes` in the
UDL, proto `bytes`, zero base64 in the path? If not, fix the design before merging.

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
| `ServerUserId` | 36-char UUID `14f28d31-…` | above the seam: gRPC, Core Data, transcript, contacts, `conversation_id`, mailbox and stream cursors |
| `CryptoDeviceId` | 32-char hex `6f5e37ac…` | below the seam: `local_user_id`, `contact_id`, the AD, Keychain session accounts, every `plan_*`; also device linking and QR |

**A session is a ratchet between two devices**, so everything passed to the Rust session layer
(`set_local_user_id`, `init_session`, `init_receiving_session`, `encrypt_message`,
`decrypt_message`, `remove_session`, `forget_contact_state`, every `plan_*`) is a
`CryptoDeviceId`. The AD binds a **pair of device ids**; the core does not know `ServerUserId` and
must not learn it. Mixing the spaces breaks the Double Ratchet AD → permanent AEAD failure on
every session, with no error — the message simply does not open.

This table said the opposite until 2026-09-05, naming `ServerUserId` as correct for
`local_user_id` and `contact_id`. That was true until 2026-08-26 and then was not, and the file
that overrides every other instruction went on saying it. `decisions/identity-spaces.md` carries
why the original fix ("always `ServerUserId`") was the accidental half of the right answer:
the bug required the two sides to *agree*, and an account cannot name a ratchet.

`SessionAddressing` is the conversion and `PeerAddress` is the seam made into an object — an
account always, a device when the event names one. Prefer them to a bare `String` at any module
boundary.

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

**Never commit on `develop` or `main`.** `develop` is what goes to TestFlight; `main` is what goes
to the App Store. Every change goes on a topic branch cut from an up-to-date `develop`
(`feat|fix|docs|chore|test/<topic>`) and lands in `develop` through a GitHub pull request.
`develop → main` is the release step, and the owner takes it. Agents push and open the PR only
when asked.

From 2026-09-11 to 2026-10-01 changes went straight to the default branch across the
construct-* repos — two people on the project made a branch per change look like ceremony. That
was reversed on purpose: the habit has to be in place before there is an App Store release for it
to break. A commit that landed on `develop` by mistake and is not pushed moves off it with
`git branch <topic> && git reset --keep origin/develop && git switch <topic>`. Pushed history is
never rewritten.

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
