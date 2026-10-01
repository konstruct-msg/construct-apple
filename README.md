# Konstruct

**Privacy-first, end-to-end encrypted messenger whose message content is protected by hybrid post-quantum cryptography.**

[![Rust](https://img.shields.io/badge/Rust-1.96+-orange.svg)](https://www.rust-lang.org/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-red.svg)](https://swift.org/)
[![UniFFI](https://img.shields.io/badge/UniFFI-0.30-blue.svg)](https://mozilla.github.io/uniffi-rs/)
[![iOS](https://img.shields.io/badge/iOS-18.5+-black.svg)](https://developer.apple.com/ios/)
[![License](https://img.shields.io/badge/License-MPL--2.0-brightgreen.svg)](LICENSE)

> This repository (`construct-messenger`) is the SwiftUI iOS/macOS client. The cryptographic
> core, transport engine, and obfuscation proxy live in separate Rust repositories
> (see [Repository Layout](#-repository-layout)).

---

## About

Konstruct is an E2EE messenger with a terminal / ASCII aesthetic. The cryptographic core
is written in Rust and shared verbatim across platforms via UniFFI, so iOS, macOS, and the
in-progress Android client run the *same* crypto rather than reimplementing it. No external
security audit has been done yet — that is on the roadmap, not behind us.

### Principles

- ✅ **100% E2EE** — the server never sees plaintext, contact graphs in the clear, or private keys.
  Contact edges are stored as keyed hashes of both user ids, which keeps the graph out of a
  database leak — not out of the operator's reach, since the operator holds the key.
- ✅ **Forward secrecy & post-compromise security** — Double Ratchet; compromised keys don't reveal history.
- ✅ **Post-quantum message content** — X25519 and ML-KEM together, mandatory for every session,
  so an attacker must break *both*. Not every layer is post-quantum yet — see
  [what is still classical](#what-is-still-classical).
- ✅ **Versioned suites** — the wire names its cipher suite (`suite_id`); a retired suite is
  refused, never negotiated down to.
- ✅ **One Rust core, many platforms** — iOS, macOS, Android share `construct-core` via UniFFI.
- ✅ **Binary data pipeline** — no base64/JSON in the crypto path; `Data`/`[u8]` end to end.

---

## Architecture

```
+-------------------------------------------------------------+
|                  SwiftUI client (iOS / macOS Desktop)       |
|   - @Observable view models    - Core Data persistence      |
|   - CryptoManager: thin UniFFI wrapper over construct-core  |
+--------------v--------------------------------------------+
|   construct-core (Rust) via UniFFI (direct path)           |
|   - PQXDH v2 (ML-KEM-1024), Double Ratchet + PQ ratchet     |
|     (ML-KEM-768), Ed25519 + ML-DSA-65 hybrid signatures    |
+--------------+--------------------------------------------+
               | gRPC (H2 primary; H3-QUIC experimental)
               | + optional VEIL (obfs4/WebTunnel) for DPI evasion
               v
+-------------------------------------------------------------+
|   Konstruct server (Rust) behind Traefik                    |
|   - key bundles, Redis-Streams mailbox, Redpanda send bus   |
|   - NO access to plaintext                                  |
+-------------------------------------------------------------+
```

Both iOS and macOS Desktop use the direct UniFFI + gRPC-Swift path
(`CryptoManager` + `TransportRouter` + `VeilProxyManager`), built from three Rust
crates: `construct-core` (crypto, with VEIL merged in), `construct-transport`
(QUIC/H3), and `construct-veil` (obfuscation).

---

## Cryptography

Verified against `construct-core` source — names follow NIST FIPS, informal names in parens.

### Classic suite (`suite_id = 1`) — production

| Component     | Algorithm             | Purpose                      |
|---------------|-----------------------|------------------------------|
| Key agreement | **X25519** (ECDH)     | Ephemeral DH for ratcheting  |
| Signatures    | **Ed25519**           | Prekey / identity signatures |
| AEAD          | **ChaCha20-Poly1305** | Message encryption           |
| KDF           | **HKDF-SHA256**       | Key derivation               |

### Post-quantum — every session

| Component | Algorithm | Where |
|---|---|---|
| Handshake | **PQXDH v2**: X25519 and an **ML-KEM-1024** (FIPS 203, Kyber-1024) secret in the root key — the first message included | mandatory since construct-core 0.18; a first message without it is refused |
| Ratchet | **Suite 4**: Double Ratchet plus a sparse continuous **ML-KEM-768** (Kyber-768) ratchet, one post-quantum key per message | since construct-core 0.24; new epochs every few DH turns or 7 days |
| Bundle signatures | **Ed25519 + ML-DSA-65** (FIPS 204, Dilithium-3), both must verify | required on every Kyber prekey the core encapsulates to |

> The hybrid identity key is bound to the device by an Ed25519 cross-signature, which a quantum
> attacker could forge — so the core **pins** the hybrid key the first time it opens a session to
> a device and refuses a different one later. That is trust on first use, not a PQ chain to a
> root; key transparency is what would close it. ML-DSA-65 is RustCrypto `ml-dsa` on client and
> server alike, pinned by a cross-implementation interop test.
>
> Earlier versions of this file said the variant was ML-KEM-768 and that "Kyber-1024" was wrong.
> That was true before PQXDH v2 (2026-09-25): the handshake now uses ML-KEM-1024, and ML-KEM-768
> is only the ratchet's.

### What is still classical

Post-quantum protection covers the **content** of one-to-one messages and the attachments they
carry. These layers are not post-quantum yet:

- **Who sent a sealed message.** The sender certificate is sealed with X25519 only; a recorded
  message reveals its sender to a future quantum attacker, not its content.
- **Calls.** WebRTC DTLS-SRTP with an ECDHE handshake — a recorded call can be decrypted later.
- **Groups.** The MLS engine uses a classical ciphersuite; groups do not ship yet.
- **Authentication to the server** — device and recovery signatures, server-signed sender
  certificates — is Ed25519. A forgery acts on the account; it does not decrypt messages.

The full table, with sources and the open items `PQC-1`…`PQC-6`, is in the protocol book:
[Threat Model — Post-quantum coverage](https://konstruct-msg.github.io/construct-protocol/01-threat-model.html#post-quantum-coverage).

### Suite binding (anti key-substitution)

Prekey signatures are **domain-separated** by a prologue that binds the signature to the
suite, preventing key-substitution attacks across cipher suites
(`"KonstruktX3DH-v1" ‖ suite_id ‖ public_key`). Byte-exact format lives in the protocol
spec in `construct-docs`, not here.

---

## Offline delivery & privacy

Konstruct delivers to offline recipients, but deliberately as an **ephemeral, time-bounded**
mailbox — not a permanent inbox. This is a privacy choice, not a limitation to be "fixed".

- **Online recipient** → pushed straight to the live gRPC stream; nothing is stored.
- **Offline recipient** → the (already E2E-encrypted) message is queued in a per-user and
  per-device **Redis Stream**, and an **APNs silent push** wakes the app to reconnect.
- **On reconnect** → the app drains its stream; messages are **deleted immediately** after
  delivery.
- **Durable send** → the send path uses a 2-phase commit over the Redpanda/Kafka bus
  (idempotent by `temp_id`), so a network failure mid-send never duplicates or loses a message.

**The TTL nuance — read this:** queued messages are held in Redis **only**. They are
**never written to a database** (no server-side history, and no record of who sent them),
and they **expire after a TTL** (tied to the session TTL; streams are also trimmed by age).
If a recipient stays offline **longer than the TTL**, undelivered messages are
**auto-deleted** and will not arrive. The offline window is finite by design — Konstruct is
not a store-and-forward archive.

---

## Building

All three Rust crates must be cloned alongside this repo:

```
~/Code/
├── construct-core/        # crypto core  → ConstructCore.xcframework
├── construct-transport/   # QUIC/H3/gRPC → ConstructTransport.xcframework
├── construct-veil/        # obfs4/WebTunnel obfuscation (VEIL, merged into ConstructCore.xcframework)
└── construct-messenger/   # this repo (SwiftUI app)
```

The `*.xcframework` binaries are **not** tracked in git — build them after cloning:

```bash
# 1. Build the crypto core — iOS device + simulator + macOS
cd ~/Code/construct-messenger
./build_crypto_lib.sh --all

# 2. Build the transport library
./build_transport_lib.sh --all           # wraps construct-transport/build_ios.sh

# 3. Regenerate UniFFI Swift bindings (after any core API change)
cd ~/Code/construct-messenger
./generate_swift_bindings.sh

# 4. Build & run
xcodebuild -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
# …or open ConstructMessenger.xcodeproj in Xcode and ⌘R
```

> **`--all` on both, unless you are rebuilding one platform on purpose.** A narrowed build leaves
> the other slices from an older core: `build_crypto_lib.sh` warns when it notices, and
> `build_transport_lib.sh` silently omits `macos-arm64`, which `Construct Desktop/` then fails to
> link against — an xcframework that looks perfectly well-formed.
>
> Nothing in a `-destination` survives an Xcode upgrade: runtimes are replaced, so never pin
> `OS=`, and simulator **names** turn over with them (`iPhone 17` no longer exists). Read the
> current one from `xcrun simctl list devices available` rather than from this file.

**Requirements:** Rust 1.96+ · Xcode 16+ · iOS 18.5+ deployment target · UniFFI 0.30.

---

## Repository Layout

```
construct-messenger/
├── ConstructMessenger/
│   ├── Views/                  # SwiftUI views (terminal/ASCII design system)
│   ├── ViewModels/             # @Observable view models
│   ├── Services/               # session, messaging, healing, crypto orchestration
│   ├── Security/
│   │   └── CryptoManager.swift # UniFFI wrapper around construct-core
│   ├── Networking/gRPC/        # gRPC channel + generated protobuf + VEIL
│   ├── Utilities/              # CT design tokens (ConstructTheme.swift)
│   ├── Fonts/                  # bundled JetBrains Mono (UIAppFonts lists bare file names)
│   ├── {en,ru,ja,fr}.lproj/    # localization — all four held to key parity by CI
│   └── construct_core.swift    # generated UniFFI bindings (do not edit)
├── ConstructMessengerTests/    # the Xcode suite (the ConstructMessenger scheme runs it)
├── Construct Desktop/          # macOS client — same core + gRPC path, no public build
├── fastlane/metadata/          # App Store listing copy, per locale — reviewed as a diff
├── scripts/                    # build/test/simulator tooling
├── tests/                      # Python network + DPI probes (not the Xcode suite)
├── docs/                       # reference for tooling in this repo
├── build_crypto_lib.sh         # rebuild construct-core → ConstructCore.xcframework
├── generate_swift_bindings.sh  # regenerate UniFFI bindings
└── AGENTS.md                   # hard invariants for contributors and AI agents
```

See **[`AGENTS.md`](AGENTS.md)** for design-system rules, the session lifecycle, the binary-data
pipeline, and identity-space invariants. Longer-form docs live in the `construct-docs` vault; the
index at the top of `AGENTS.md` says which document covers what.

---

## Testing

```bash
# Rust core
cd ~/Code/construct-core && cargo test --features post-quantum

# iOS app (unit + crypto-wire integration)
cd ~/Code/construct-messenger
xcodebuild test -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -parallel-testing-enabled NO

# a single class, without simulator clones
scripts/test_run.sh ConstructMessengerTests/FooTests
```

See [`docs/TESTING.md`](docs/TESTING.md) for the tooling and
[`docs/TWO_SIM_STAND.md`](docs/TWO_SIM_STAND.md) for the two-simulator send/receive stand.

---

## Status

**App:** v0.20.0 (686) — Alpha, TestFlight · **Core:** construct-core v0.25.0

### Working
- [x] Rust crypto core — X3DH + Double Ratchet, versioned suites
- [x] PQXDH v2 — ML-KEM-1024 in every session's initial key, mandatory
- [x] Post-quantum ratchet (suite 4) — ML-KEM-768 epochs, one post-quantum key per message
- [x] Hybrid Ed25519 + ML-DSA-65 signatures — required on every Kyber prekey, with the hybrid key
      pinned per device; client and server share one RustCrypto implementation
- [x] UniFFI iOS integration; binary (CFE) session persistence
- [x] QUIC / HTTP-3 / gRPC transport engine (H2 fallback on iOS)
- [x] VEIL obfuscation (obfs4 + WebTunnel pluggable transports, opt-in)
- [x] 1:1 messaging, session healing, account recovery (BIP39)
- [x] Offline delivery — ephemeral per-device Redis-Streams mailbox (no DB persistence, TTL-bounded), drained on reconnect; Redpanda/Kafka bus with 2-phase-commit send; APNs silent-push wake-up
- [x] Voice calls (WebRTC + CallKit) — video is not implemented (`CallsFeature.isVideoEnabled`)
- [x] App-lock (PIN + biometrics, duress PIN)

### In progress / planned
- [ ] Multi-device. Linking and transcript sync (SENDER_SYNC) are implemented and unit-tested,
      and that is not the same as working: the two-simulator stand has not yet carried a copy
      through to a second device's transcript, so nothing here has been confirmed on hardware.
      It stays out of the Working list until it has.
- [ ] Post-quantum beyond message content: a hybrid sealed-sender box, call keys derived from
      the post-quantum session, a hybrid MLS ciphersuite before groups ship (`PQC-1`, `PQC-4`,
      `PQC-5` in the protocol book)
- [ ] Take the last classical step out of the hybrid signature chain — the hybrid key is bound to
      a device by an Ed25519 cross-signature and held by a first-use pin
- [ ] Cluster (group) messaging
- [ ] macOS Desktop — direct core + gRPC path builds; no public build
- [ ] Android client

---

## License

MPL-2.0 — see [LICENSE](LICENSE).

## Acknowledgments

- **Signal Foundation** — Double Ratchet & X3DH
- **RustCrypto** & **Mozilla (UniFFI)** — crypto crates and FFI tooling
- **NIST** — FIPS 203 (ML-KEM) & FIPS 204 (ML-DSA) standardization

## Trademark

**Konstruct™** / **Конструкт™** and the logo are trademarks of Maxim Eliseyev. The open-source
license on this code does **not** grant trademark rights — see [TRADEMARK.md](TRADEMARK.md).
Forks that distribute a modified version must rebrand.
