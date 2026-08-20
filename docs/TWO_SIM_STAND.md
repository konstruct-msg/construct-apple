# Two-simulator E2E stand

`scripts/two_sims.sh` runs the app on two dedicated simulators (`Construct-A` iPhone 17 Pro,
`Construct-B` iPhone 17) for send/receive scenarios that cannot exist on a single device.

This document lives in this repo rather than in the docs vault because it documents a script in
this repo: the two change together and belong in the same commit.

```bash
./scripts/two_sims.sh run     # up + build + install + launch on both
./scripts/two_sims.sh pair a  # invite from A's pasteboard → openurl on B
./scripts/two_sims.sh env     # UDID_A / UDID_B / BUNDLE_ID for UI-automation tools
./scripts/two_sims.sh reset   # erase both → clean onboarding
./scripts/two_sims.sh shot    # screenshots → logs/two_sims/ (gitignored)
```

## What the stand can and cannot answer

**The stand is a happy-path UI harness, not a protocol test bed.** APNs push, VoIP + CallKit
audio, background decrypt, and anything driven by network conditions (session healing, offline
delivery, stream replay) do not reproduce faithfully on a simulator. Those belong in
`ConstructMessengerTests` against a real server — a green two-sim run says nothing about them.

## Pairing goes through the pasteboard, never the QR

A simulator has no camera, so the scan path is undrivable. Settings ▸ INVITE ▸ COPY LINK carries
the same invite; `simctl pbpaste` reads it and `pair` hands it to the other sim.

That command rewrites the copied HTTPS share link to the `konstruct://` scheme on purpose — the
HTTPS form is a universal link and needs an apple-app-site-association fetch, so a simulator opens
it in Safari instead of the app.

Simulator pasteboards auto-sync with the host, so the host clipboard bleeds in; `pair` rejects a
buffer that holds no invite rather than guessing.

## Two simulators already are two accounts

Separate container, Keychain and Core Data per sim. Do **not** add test-account launch arguments
or environment flags to the app to distinguish them: the app reads no launch args today
(`ProcessInfo` use is Preview detection only), and a test-only branch in production code is a
worse price than one `reset`.

## `link` is the other topology, and the only one that exercises SENDER_SYNC

`pair` makes the two sims into two accounts talking to each other. `link` makes them **one account
on two devices** — which is what a multi-device copy needs, and what two sims are not by default.
Testing SENDER_SYNC against a `pair`ed stand exercises nothing: the code never runs.

```bash
./scripts/two_sims.sh link a   # token from A's log → B's pasteboard
```

Then on B: `settings.devices` → `devices.linkNew` → `qrScanner.paste`. On a **fresh** B the
designed route is onboarding instead: `onboarding.existingIdentity` → LINK THIS DEVICE → SCAN A
CODE → the same paste button.

Three things the flow needs that `pair` does not:

- **The token is only inside the QR image.** A DEBUG-only line in `DeviceLinkViewModel` prints the
  full `konstruct://link?token=…`, and `link` greps it out of A's log. Release builds never print
  it — it authorises joining the account, and the log is exportable from Settings.
- **`konstruct://link` is deliberately not a deep link.** `DeepLinkHandler` routes everything but
  veil-config to the contact parser, so `simctl openurl` does not work here and must not be made
  to: a tapped link that silently joins your device to someone's account is the wrong default.
  The scanner accepts the prefix (`QRScannerView.handleScannedCode`), and pasting is a deliberate
  act, which is the point.
- **iOS asks before pasting** ("would like to paste from CoreSimulatorBridge"). Allow it; the tap
  lands on the alert, not the app, and nothing is logged until you do.

Linking wipes B's own account (`confirmLink` → `deleteDeviceKeys` → fresh device id). If A's only
contact *was* B's old account, the stand is left with a conversation whose peer has no devices —
erase B and re-link rather than trying to reason about the result.

**Restart both after linking.** A learns its new sibling only when its own-device cache expires
(1 h) or the process restarts, and B's message stream stays authenticated as the old identity
until relaunch — copies then arrive addressed to an account B no longer is.

## Typing goes through the simulator's active keyboard, so verify what landed

UI automation sends HID key codes: under a Russian layout `alice` arrives as `фдш`, and the
failure looks like a broken app. `up` forces `en_US`, but iOS restores the previous input source
on app relaunch, so always read the field back. A first burst into an empty field also loses
everything after the first character — type with `replaceExisting`, and expect to repeat it.

## Driving the stand does not need the MCP server

Taps and typing normally come from XcodeBuildMCP. When it is not connected, the stand is not
stuck at looking: the `axe` binary that server drives ships inside its own brew package and
takes the same arguments directly.

```bash
AXE=/opt/homebrew/Cellar/xcodebuildmcp/*/libexec/bundled/axe
"$AXE" describe-ui --udid "$UDID_A"                 # a11y tree as JSON
"$AXE" tap --id contactQR.copyLink --udid "$UDID_A" # by identifier, as below
```

`describe-ui` lags a navigation by a second or two, and a pushed destination appears *after* the
presenting screen's subtree rather than replacing it — so a `head -30` of the tree reads as "the
tap did nothing" when the screen has in fact changed. Re-read, and screenshot before concluding.

The app writes its own log to `Documents/Logs/current.log` inside the data container
(`xcrun simctl get_app_container <udid> <bundle> data`). That file, not `log stream`, is where
`[LinkParser]`, `[InviteVerifier]` and `[Retry]` live — and `[Retry]` prints the raw error, which
is how a gRPC status gets read without rebuilding to add a log line. The container path changes
on reinstall; resolve it every time rather than caching it.

## Address the UI by identifier, never by pixels or position

a11y-tree reads are cheap and stable; pixel comparison is neither. New UI on a happy path gets an
`accessibilityIdentifier`, and the string comes from `ConstructMessenger/Utilities/AccessibilityIdentifiers.swift`
(`A11y.*`) — never a literal at the call site. The consumer is outside this repo, so a rename
breaks a scenario that still compiles.

- Rows and messages are addressed by id (`A11y.Chats.row(chat.id)`, `A11y.Chat.message(id)`),
  never by position — the list reorders on every incoming message.
- `A11y.Chat.messageStatus` encodes the delivery status **in the identifier**
  (`chat.message.<id>.status.delivered`). The status icons are bare SF Symbols with no label, and
  identifiers are neither localized nor user-visible — which makes them the right channel for
  machine-readable state, with no invented user-facing string.

## Three SwiftUI accessibility facts, none of which fail loudly

Each cost a live run to learn.

1. **An identifier on a container overwrites its descendants'.** `chat.message.<id>` was applied
   to the whole bubble row, so it stamped the delivery-status icon too and `.status.delivered`
   never existed. Scope an identifier to the leaf it names, never to a row that also holds
   independently-addressed children.

   This recurred on 2026-08-16 in `IssuedInvitesView`, written after the rule was recorded here:
   the act identifier on the row stamped the revoke button, and `A11y.IssuedInvites.revoke(id)`
   matched nothing. Writing the rule down did not prevent it, so **check it** — after adding a
   row with an addressable control inside, grep the identifier out of a live `describe-ui`. A
   declared identifier that is not in the tree is the normal outcome, not the surprising one.

2. **An unlabeled `Image` is dropped from the accessibility tree, identifier and all.** The status
   icons carried an identifier for a whole session and matched nothing. The `accessibilityLabel`
   is what makes the element exist — it is a prerequisite for the identifier, not a nicety. (It is
   also the only reason VoiceOver can read delivery state.)

3. **`snapshot_ui` does not print elements whose action is `none`.** The status icon is neither
   tappable nor text, so it is invisible in a snapshot even when present. Assert it with
   `wait_for_ui` on an `identifier` selector; absence from a snapshot proves nothing.
