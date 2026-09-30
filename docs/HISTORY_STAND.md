# History transfer stand (phone ↔ Mac)

`scripts/history_stand.sh` runs the post-link history transfer between an iPhone (or a simulator)
and Construct Desktop, and reads both sides' logs of one transfer side by side. The scenarios and
their pass criteria are stage 8 of `client/specs/DEVICE_LINK_HISTORY_TRANSFER_PLAN.md` in the
vault; this file documents the script, and the two change together.

## Why a build flag

Post-link transfer is off in the product (`DeviceLinkHistorySyncPolicy.isPostLinkEnabled = false`)
until this stand passes. The stand build turns it on with `-DHISTORY_STAND`, which the script
passes and **no configuration in the project defines** — Beta keeps `DEBUG` and goes to TestFlight,
so `DEBUG` cannot be the gate. Until 2026-09-29 the gate was a `DEBUG` static nothing could set.

```bash
./scripts/history_stand.sh mac        # build Desktop, relaunch it, log → logs/history_stand/mac.log
./scripts/history_stand.sh phone      # build iOS, install on $PHONE, launch
./scripts/history_stand.sh join       # Flow B: the Mac's join link → the simulator's pasteboard
./scripts/history_stand.sh logs       # pull the phone log, show history lines from both sides
./scripts/history_stand.sh snapshots  # snapshot ids both sides saw
./scripts/history_stand.sh stop       # quit Desktop
```

`PHONE` is a physical iPhone's UDID (`xcrun devicectl list devices`) or `sim:<name|UDID>`. It
defaults to `sim:Construct-A`: linking erases the new device's account, and a default must not
point at someone's phone.

## Reading a run

- **One transfer, two logs, one tag.** Every history line carries `snapshot=<8 hex>` —
  `HistorySnapshotIdentity.tag`, the first four bytes of the core's snapshot id. `snapshots`
  prints the tags both sides logged; a transfer only one side saw is the first thing to explain.
- **Who asks.** Since 2026-09-30 the device that already holds the history (device 1) is asked
  whether to send it; the new device waits (`history_sync_waiting_for_other_device`) with Import
  file and Skip as its only choices. `Post-link history sync offered role=` in either log says
  which side the app thinks it is.
- **The Mac's log** is the process's stderr with `OS_ACTIVITY_DT_MODE=YES`: its file log sits in the
  sandbox container, which the terminal cannot read under TCC. The app is started through `open`,
  because a binary launched from a shell opens no window.
- **Flow B on a simulator.** A simulator has no camera, so `join` reads the link from the Mac's
  `DeviceLink stand join request:` line (`DEBUG` only) and puts it on the pasteboard; then
  "Link New Device" → paste. The link names a device and its public key and grants nothing — the
  phone's approval does.

## What it cannot answer

A simulator shares the Mac's network, so a nearby transfer from it is not two devices on Wi-Fi,
and it has no Local Network permission prompt: rows about that permission and about large media
need a physical phone.
