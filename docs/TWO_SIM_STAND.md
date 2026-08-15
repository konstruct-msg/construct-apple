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

## Typing goes through the simulator's active keyboard, so verify what landed

UI automation sends HID key codes: under a Russian layout `alice` arrives as `фдш`, and the
failure looks like a broken app. `up` forces `en_US`, but iOS restores the previous input source
on app relaunch, so always read the field back. A first burst into an empty field also loses
everything after the first character — type with `replaceExisting`, and expect to repeat it.

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

2. **An unlabeled `Image` is dropped from the accessibility tree, identifier and all.** The status
   icons carried an identifier for a whole session and matched nothing. The `accessibilityLabel`
   is what makes the element exist — it is a prerequisite for the identifier, not a nicety. (It is
   also the only reason VoiceOver can read delivery state.)

3. **`snapshot_ui` does not print elements whose action is `none`.** The status icon is neither
   tappable nor text, so it is invisible in a snapshot even when present. Assert it with
   `wait_for_ui` on an `identifier` selector; absence from a snapshot proves nothing.
