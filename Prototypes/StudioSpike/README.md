# Studio spike

The program-audio path of Construct Desktop's studio mode, as a command-line tool and not yet in
the app: capture → FLAC 48 kHz / 24-bit → WebRTC data channel → playout buffer. The design it
tests is `decisions/studio-mode-on-desktop.md` in the vault; progress is in `todo/205`.

macOS 14.2+ on Apple silicon. WebRTC is the same build the app's calls use (`../../Packages/WebRTC`),
with the same field trial (post-quantum DTLS first).

```sh
swift test                                   # codec bit-exactness, wire frame, playout buffer
swift build && B=.build/debug/studio-spike
$B loopback --seconds 30                     # both ends in-process, every sample checked
```

## With Reaper, two Macs on one LAN

Set the host's output device to 48 kHz in Audio MIDI Setup, and start Reaper playing.

```sh
# host
$B send --listen 7700 --source app:com.cockos.reaper --dump sent.s32
# listener
$B recv --connect HOST_LAN_IP:7700 --play --dump recv.s32
# afterwards, with recv.s32 copied next to sent.s32
cmp sent.s32 recv.s32     # "EOF on recv.s32" = everything received matched bit for bit
```

The first `send` with `app:` asks for the audio-capture permission (System Settings › Privacy &
Security), attributed to the terminal app that ran it. Without it the tap delivers silence, and
`send` says so.

Across NAT add `--stun stun:HOST:PORT` on both ends. There is no TURN in the spike.

The SDP goes over plain TCP, unauthenticated: a LAN you trust only. In the product it travels
inside the session, as call SDP does.

## What it prints

`recv` every 5 s: received bitrate, playout fill, drift (ppm, the fill level's slope once
playing — needs `--play`, since without an output nothing drains the buffer), underruns, gaps,
`verified/mismatched` (with `--verify` against `--source tone`), RTT.
