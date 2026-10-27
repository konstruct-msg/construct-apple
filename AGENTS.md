# AGENTS.md — Construct Messenger

The rules this project paid for in its first year, and the invariants of this repository. Each
line is here because breaking it already cost something; the incident behind it lives in the
vault. If a rule here and your plan disagree, the rule wins until a `decisions/` note says
otherwise.

| Area | Read first |
|---|---|
| Why these rules exist, and the checklist before any new protocol feature | `~/Code/construct-docs/decisions/rules-from-the-first-year.md` |
| Build, first clone, target flags | `~/Code/construct-docs/client/ios/BUILD_GUIDE.md` |
| UniFFI bindings | `~/Code/construct-docs/client/ios/UNIFFI_GUIDE.md` |
| Design system | `~/Code/construct-docs/client/ios/DESIGN_SYSTEM_RULES.md` |
| Sessions, keychain, crypto/transport path | `~/Code/construct-docs/client/ios/ARCHITECTURE_NOTES.md` · `~/Code/construct-docs/decisions/sessions-renew-by-sending.md` |
| Sealed control channel | `~/Code/construct-docs/client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md` |
| Binary data / CFE format | `~/Code/construct-docs/client/shared/construct-ffi-binary-format.md` |
| Product wording | `~/Code/construct-docs/client/GLOSSARY_PRODUCT_LANGUAGE.md` |
| Testing | `docs/TESTING.md` · two-simulator stand `docs/TWO_SIM_STAND.md` |
| `Networking/gRPC/VEIL/`, `Services/Calls/` | `~/Code/construct-docs/decisions/ice-connection-loop-complexity.md` |
| Everything else | `~/Code/construct-docs` (vault; its own `AGENTS.md` is authoritative) |

Privacy-first E2EE messenger. Crypto core in Rust (`construct-core`, separate repo) via UniFFI;
client SwiftUI-only. Layout: `ConstructMessenger/` iOS · `Construct Desktop/` macOS ·
`ConstructMessengerTests/` · `scripts/` · `docs/`. Siblings: `~/Code/construct-core`,
`~/Code/construct-transport`, `~/Code/construct-veil`, `~/Code/construct-docs`.

---

## The Zen of Konstruct

```
Someone has solved it before. Read them first.
The core decides; the app executes.
A message names the state it means. Time is not an address.
Reproduce, then fix.
One meaning, one carrier.
Bytes stay bytes.
Measure, then build.
The effect is the proof, not the exit code.
A test that cannot fail is worse than no test.
Boring before new.
Temporary is permanent, unless something checks it.
What nothing reads is not sent.
Silence is the worst failure: a message that never appears raises no error.
```

## The twelve rules

**Protocol** — where almost all of the year's cost went.

1. **Prior art first.** Before any protocol mechanism, write down how Signal / MLS (RFC 9420) /
   Matrix solve it and why we deviate. END_SESSION spent eight months reinventing what Signal
   has had since 2016: a session renews by sending. Group key management is MLS, not ours.
2. **The core decides, this app executes.** If two clients must compute it identically for a message
   to be readable — or it touches ratchet/session state, or decides which sessions an operation
   touches, or a session's lifecycle phase — it is a `construct-core` API, written first. This
   app does network, Core Data, Keychain, UI, and the account → device-set mapping. Before
   writing a session or crypto decision in Swift, open `construct_core.udl`: it is already there
   more often than not. Known exceptions still in Swift, with their destination (the core
   machine): the account-keyed `sessionPhases` and the per-scope init locks — do not extend them.
3. **A control message names the state it refers to** (epoch, ratchet key, number), so the
   receiver tells current from stale exactly. A fix that adds a timer, cooldown, window,
   tie-break or retry budget means the message has no address — stop and give it one.
4. **Reproduce before fixing.** A symptom like "breaks every 5–6 messages" is not fixed without a
   stand that reproduces it deterministically (`docs/TWO_SIM_STAND.md`). The fix counts when the
   stand that was red turns green.
5. **One meaning, one carrier; different meanings, different types.** Every identifier is its own
   type. Before adding a field, counter, constant or timeout, read
   `~/Code/construct-docs/decisions/one-meaning-two-carriers.md`. A comment saying two things
   "must match" means one should be a call to the other.

**Data and evidence**

6. **Binary stays binary**, source to destination — see *Binary data* below.
7. **Measure, then build.** Network, censorship, performance: a measurement on the real path
   before a mechanism. Five obfuscation designs preceded the measurement that settled it.
8. **Verify the effect, not the exit code.** A backup by restoring it, a delete by querying after
   it, an alert by its series, a deploy by the version it reports.

**Tests and process**

9. **A test must be able to fail.** Put the decision in a pure function, test that, and
   mutation-check every new test: one mutation at a time, an unapplied mutation is fatal, restore
   by shasum, rerun the baseline. A test that cannot fail occupies the place where someone would
   otherwise have looked.
10. **Depth before breadth.** A new surface (groups, rooms, Studio to release) starts when the
    last one is boring on the stand and with testers. Testers who stop testing is a P0.
11. **A temporary exception has an end date and a check** that notices the debt growing. "Until
    translated" left two locales hundreds of keys behind.
12. **A branch and a PR, always** — see *Git* below.

**A change on the delivery or crypto path answers three questions** in its commit message, before
it lands: (1) what does the server or any relay learn that it did not before; (2) what can a
party — server, sender, sibling device — withhold or substitute that it could not before; (3)
which trust boundary moves, and which way. An honest "something" to 1 or 2 is a `decisions/`
note, not a merge.

**A producer with no consumer is a defect.** A send, signal or action lands with its reader in
the same change, or is removed; a handler no producer reaches is wired up or deleted.

---

## Sessions and crypto

- **A session is a ratchet between two devices.** Everything below the seam takes a
  `CryptoDeviceId`; the core never learns `ServerUserId`. Mixing them breaks the AD: every message
  fails AEAD, silently.

  | Type | Format | Use |
  |---|---|---|
  | `ServerUserId` | 36-char UUID | above the seam: gRPC, Core Data, transcript, contacts, cursors |
  | `CryptoDeviceId` | 32-char hex | below the seam: `local_user_id`, `contact_id`, AD, Keychain session accounts, every `plan_*`, linking, QR |

  `SessionAddressing` converts; `PeerAddress` is the seam as an object. A caller holding an
  account expands it with `deviceIds(ofPeer:)` and acts on the whole set — never `.first` of a
  device set. `pinnedDevice(ofPeer:)` is the offline answer only and never appears under the
  crypto layer (`CryptoIdentitySpaceTests` fails on either). `PeerDevice` is a local store, not
  the authority on a peer's device set.
- **A session renews by sending.** A message with the handshake header opens a new state beside
  the current one; the core keeps previous states and promotes the one that decrypts. An
  unreadable message is answered with DECRYPTION_ERROR (type 28) naming the state. Reset, chat
  or contact deletion and logout are local — nothing is sent. **Never rebuild:** END_SESSION,
  SESSION_RESET_INIT, `session_ready`, ping, confirm windows, tie-breaks, heal, cooldowns,
  stale-by-timestamp checks.
- **Receiving fetches nothing.** A first message opens with the key its sender certificate names,
  once the core has checked the server's signature. Never fetch the sender's bundle to receive.
- **The core owns the queue of messages waiting for a session**; this app keeps envelopes and must
  not grow a second queue.
- **Ask the core for the operation, never for the key**: `signWithDeviceKey`,
  `openSealedToDevice`, `deviceCopyTag*`, `newMlsStore`/`importMlsStore`. The Keychain holds the
  device keys once, in the key record the core loads from.
- **History transfer is the core's protocol** (`HistorySender` / `HistoryReceiver`); this app
  moves bytes. `HistoryChannelTests` fails on a CryptoKit import on that path.
- **Sealed sender:** after unseal, route only on the inner `contentType`
  (`ContentTypeRouting.kind(for:)`). The outer `messageType` is generic on purpose.
- **Content types are cross-client.** Values come from the generated
  `Shared_Proto_Core_V1_ContentType`, never a fresh literal. Meaning lives in
  `~/Code/construct-protos/conformance/knst_content_types.json`; a new type adds its row in the
  same change, or `ContentTypeConformanceTests` reddens.
- **Keychain:** state a background or locked push decrypt needs uses
  `kSecAttrAccessibleAfterFirstUnlock*` (`KeychainManager.cryptoKeyAccessible`), never
  `WhenUnlocked*`.
- **Device keys are deleted only on gRPC UNAUTHENTICATED (16) / PERMISSION_DENIED (7)** — never on
  a network error.
- **All crypto goes direct via UniFFI.** Two xcframeworks: core+veil → `ConstructCore`,
  transport → `ConstructTransport`. No engine/`EngineAdapter` layer.
- **Generated files are never hand-edited**: `construct_core.swift`
  (`./generate_swift_bindings.sh`), `Networking/gRPC/Generated/` (`./generate_grpc_swift.sh`).
- **VEIL is not ICE.** VEIL is our obfuscation layer (`Networking/gRPC/VEIL/`); ICE is WebRTC NAT
  traversal in calls (`Services/Calls/`).

## Binary data

- No base64 except at true text boundaries (QR, deep links, `mailto:`); no JSON for binary
  payloads — protobuf `bytes` or CFE.
- The UniFFI boundary passes `bytes` (Swift `Data`), never `sequence<u8>` or `String`
  (`construct-core/tests/udl_bytes_test.rs` fails on a new one). A value from the core is already
  `Data`: do not wrap it in `Data(…)`.
- Session state persists as CFE from `export_session_bytes_for`, never the JSON export.
- `Codable` `Data` in UserDefaults is fine; never hand-roll base64 around a typed `Data`.
- Core Data `encryptedContent` is Binary Data; `ChatMessage.content` is `Data`, control
  messages use `Data()`.
- A field left out on purpose at a boundary (unseal, FFI, wire → model) says so in a comment.
  Better: copy the value and assign the few fields that change, rather than listing twenty.

## Build

```bash
./build_crypto_lib.sh --all      # ConstructCore.xcframework (iOS + sim + mac)
./build_transport_lib.sh --all   # ConstructTransport.xcframework (iOS + sim + mac)
```

- **`--all`, always.** Without it the macOS slice is missing and `Construct Desktop/` fails to
  link against an xcframework that looks fine. The binaries are not in git; `Info.plist` is.
- **CI cannot build the app.** It checks localization, the privacy manifest, versions, forks and
  this file. Build and test locally — and build `Construct Desktop` after any shared change.
- **`ConstructMessenger` is the scheme with the tests.** One that builds the app alone runs zero
  tests and reports success. Tests run serially (`-parallel-testing-enabled NO`).
- **Never pin `OS=` in a `-destination`**; check `xcrun simctl list devices available`.
- **Version and build number live on the project, not a target**, so the app and
  `ConstructNotifications/` share one (`scripts/check_build_versions.sh`). Desktop keeps its own.
- **A forked dependency is listed in `.github/forks.json`**; moving its pin changes the SPM
  reference, `Package.resolved` and that file in one PR (`scripts/check_forks.py`). After any
  resolve, check that only the pin you meant moved.
- **Xcode Previews** run in the app target with the Debug configuration (scheme
  `ConstructMessenger`). If they break, check WebRTC (`Packages/WebRTC`) and the toolchain first.
  A separate preview package shares the theme file, never copies it
  (`~/Code/construct-docs/decisions/one-theme-file-shared-not-copied.md`).

## Design system

**Affordance is native, identity is ours.** Controls and state (buttons, toggles, navigation,
selection, status, disclosure) look like the platform's. Structure and rhythm (grid, hairlines,
section headers, palette, dark default, circular identicons, monospace chrome) are ours. Message
text is the reader's. The test: does a person have to learn this app to know what it does? Then
it is a control and looks native.

- **No new ASCII control or status, anywhere.** SF Symbols and native controls for anything
  interactive or stateful (`CTStatusBadge`, `Toggle`, `chevron.*`); ASCII only as structure
  (`> TITLE`, separators, keycap hints, debug surfaces). Never regress a converted control. A new
  surface is built this way from the start; a missing token lands first.
- **Tokens only** — `ConstructMessenger/Utilities/ConstructTheme.swift`: `Color.CT.*`,
  `CTFont.*`, `CTRadius` via `CTShape.*()`, `CTLayout`, `CTSpace`, `.glassCapsule()`. No magic
  numbers; when editing a file with a literal, migrate that call site. Background `Color.CT.bg`
  via `.ctBackground()`.
- **Two surface languages, never mixed on one control:** form/card (`CTRadius.card`, solid) vs
  composer/glass (`pill`, `.glassCapsule()`).
- **Fonts.** The chrome is monospace (`CTFont.title … micro`, `CTFont.ui`; `CTFont.mono` for
  machine output). Message text — bubbles, composer, captions — is `CTFont.message`, the one
  face and size the reader chooses (system by default); nothing else gains a preference — the
  product is designed, not configurable. No `.system(...)` or `.monospaced` at a
  call site. JetBrains Mono is bundled (`ConstructMessenger/Fonts/`); `UIAppFonts` lists bare
  file names, and `ThemeTypographyTests` asserts the faces resolve.
- **Bars are the system's.** `.navigationTitle` + `inlineNavTitle()`, `.toolbar` items with a
  symbol and a title; a sheet with a title or action is wrapped in `.sheetNavigation()` at the
  presenting site. A conversation hides the tab bar with `.hidesTabBar()`. Moving chrome into the
  bar: check every host, the iPad split view included.
- **Debug-only UI**: `Color.CT.debug` under `#if DEBUG`.

## Localization

- Every visible string is `NSLocalizedString("key", comment: "")`.
- **New keys go to every locale in the same commit:** `en`, `ru`, `ja`, `fr`, `hy-AM`
  (`OTHER_LOCALES` in `scripts/check_localization.sh`, which CI runs). A wrong format specifier
  crashes, in the locale nobody on the team runs.
- **The product name is `Konstruct`, in Latin, undeclined, in every locale**: `в Konstruct`,
  `Konstruct-ը`, `Konstructの`.
- App Store copy lives in `fastlane/metadata/` — read `fastlane/metadata/README.md` first.
- Bar titles in sentence case. UI copy is plain language ("people / chats / device"); code keeps
  domain names.

## Code

- `@Observable` view models, `@MainActor` on view models and UI-touching services.
- Comment only non-obvious logic. Conventional Commits: `feat(scope): …`, `fix(scope): …`.

## Git

- **Never commit on `develop` (TestFlight) or `main` (App Store).** Topic branch from an
  up-to-date `develop`, PR into `develop`; `develop → main` is the owner's release step.
- Check the branch and `git status` before every commit: other sessions share the tree.
- Never `checkout -- .`, `restore .`, `reset --hard` or `stash` — name the files. Never rewrite
  pushed history. A commit made on `develop` by mistake and not pushed moves with
  `git branch <topic> && git reset --keep origin/develop && git switch <topic>`.

## Docs

The vault (`~/Code/construct-docs`) holds everything that is not a file in this repo; its
`AGENTS.md` is authoritative. Search it before an architectural decision. After work, progress
goes into the task note (`todo/NNN-*.md`, "Ход"); a decision that constrains future work goes
into `decisions/`; one line goes into `log.md`. A session log only for a root cause found the hard
way or a choice with rejected alternatives. Repo-local `docs/` holds only what documents a file
here.
