# Konstruct

**Privacy-first, end-to-end encrypted messenger with crypto-agility and post-quantum hybrid cryptography.**

[![Rust](https://img.shields.io/badge/Rust-1.92+-orange.svg)](https://www.rust-lang.org/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-red.svg)](https://swift.org/)
[![UniFFI](https://img.shields.io/badge/UniFFI-0.30-blue.svg)](https://mozilla.github.io/uniffi-rs/)
[![iOS](https://img.shields.io/badge/iOS-18.5+-black.svg)](https://developer.apple.com/ios/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

> This repository (`construct-messenger`) is the SwiftUI iOS/macOS client. The cryptographic
> core, transport engine, and obfuscation proxy live in separate Rust repositories
> (see [Repository Layout](#-repository-layout)).

---

## About

Konstruct is an E2EE messenger with a terminal / ASCII aesthetic. The cryptographic core
is written in Rust and shared verbatim across platforms via UniFFI, so iOS, macOS, and the
in-progress Android client run the *same* audited crypto rather than reimplementing it.

### Principles

- ✅ **100% E2EE** — the server never sees plaintext, contact graphs in the clear, or keys.
- ✅ **Forward secrecy & post-compromise security** — Double Ratchet; compromised keys don't reveal history.
- ✅ **Crypto-agility** — pluggable cipher suites negotiated per session (`suite_id`).
- ✅ **Post-quantum hybrid** — classical ⊕ PQ, so an attacker must break *both* to win.
- ✅ **One Rust core, many platforms** — iOS, macOS, Android share `construct-core` via UniFFI.
- ✅ **Binary data pipeline** — no base64/JSON in the crypto path; `Data`/`[u8]` end to end.

---

## Architecture

```
+-------------------------------------------------------------+
|                  SwiftUI client (iOS / macOS)               |
|   - @Observable view models    - Core Data persistence      |
|   - CryptoManager: thin UniFFI wrapper over construct-core  |
+--------------+------------------------------+---------------+
               | UniFFI (iOS)                 | EngineAdapter (macOS)
+--------------v------------+   +-------------v---------------+
|   construct-core (Rust)   |   |   construct-engine (Rust)   |
|   - X3DH + PQXDH          |   |   - QUIC / HTTP-3 / gRPC    |
|   - Double Ratchet        |   |   - token & session mgmt    |
|   - ML-KEM-768 (FIPS 203) |   |   - internal OrchestratorCore
|   - Ed25519 + ML-DSA-65   |   +-------------+---------------+
|   - crypto-agile suites   |                 | gRPC (H2 / H3-QUIC)
+---------------------------+                 |  (optional VEIL tunnel)
                                 +------------v----------------+
                                 |   construct-veil (Rust)     |
                                 |   obfs4 + WebTunnel PT      |
                                 |   DPI evasion (opt-in)      |
                                 +------------+----------------+
                                 +------------v----------------+
                                 |   Konstruct server (Rust)   |
                                 |   behind Traefik            |
                                 |   routing - key bundles     |
                                 |   Redpanda bus - Redis      |
                                 |     Streams offline mailbox |
                                 |   NO access to plaintext    |
                                 +-----------------------------+
```

iOS uses the direct UniFFI crypto path. macOS Desktop is migrating all crypto behind
`EngineAdapter` → `construct-engine` (see `AGENTS.md` → *EngineAdapter*).

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

### Post-quantum (`suite_id = 2`) — hybrid

| Component     | Algorithm                         | Status |
|---------------|-----------------------------------|--------|
| Key agreement | **X25519 ⊕ ML-KEM-768** (FIPS 203, Kyber-768) | Implemented — PQXDH mixes a Kyber OTPK into the root key |
| Signatures    | **Ed25519 + ML-DSA-65** (FIPS 204, Dilithium-3) | Implemented in core (client + server, byte-identical), **not yet activated on the wire** — identity signatures are still Ed25519 |
| AEAD / KDF    | ChaCha20-Poly1305 / HKDF-SHA256   | unchanged |

> **Note:** "Hybrid" means classical **and** PQ — both must verify / both must be broken.
> The ML-DSA-65 signature path uses RustCrypto `ml-dsa` (seed-based) on **both** client and
> server, so hybrid signatures cross-verify byte-for-byte; a cross-impl interop test pins this.
> Earlier docs that said "Kyber-1024" or "Dilithium deployed" are wrong — see
> `construct-docs` for the authoritative protocol spec.

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
**never written to a database** (no server-side history, no social-graph metadata at rest),
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
├── construct-engine/      # QUIC/H3/gRPC → ConstructEngine.xcframework
├── construct-veil/        # obfs4/WebTunnel obfuscation (VEIL)
└── construct-messenger/         # this repo (SwiftUI app)
```

The `*.xcframework` binaries are **not** tracked in git — build them after cloning:

```bash
# 1. Build the crypto core (iOS device + simulator)
cd ~/Code/construct-messenger
./build_crypto_lib.sh --ios --sim        # or --all for + macOS

# 2. Build the transport engine
cd ~/Code/construct-engine && ./build_engine.sh

# 3. Regenerate UniFFI Swift bindings (after any core API change)
cd ~/Code/construct-messenger
./generate_swift_bindings.sh

# 4. Build & run
xcodebuild -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build
# …or open ConstructMessenger.xcodeproj in Xcode and ⌘R
```

**Requirements:** Rust 1.92+ · Xcode 16+ · iOS 18.5+ deployment target · UniFFI 0.30.

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
│   ├── en.lproj / ru.lproj/    # localization (Japanese planned)
│   └── construct_core.swift    # generated UniFFI bindings (do not edit)
├── build_crypto_lib.sh         # rebuild construct-core → ConstructCore.xcframework
├── generate_swift_bindings.sh  # regenerate UniFFI bindings
└── AGENTS.md                   # conventions & deep architecture notes
```

See **`AGENTS.md`** for design-system rules, the session lifecycle, the binary-data
pipeline, identity-space invariants, and the EngineAdapter migration plan.

---

## Testing

```bash
# Rust core
cd ~/Code/construct-core && cargo test --features post-quantum

# iOS app (unit + crypto-wire integration)
cd ~/Code/construct-messenger
xcodebuild test -scheme ConstructMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'
```

---

## Status

**App:** v0.13.x (Alpha) · **Core:** construct-core v0.9.4

### Working
- [x] Rust crypto core — X3DH + Double Ratchet, crypto-agile suites
- [x] PQXDH — ML-KEM-768 hybrid key agreement
- [x] Hybrid Ed25519 + ML-DSA-65 signatures in core (client + server parity, cross-verified)
- [x] UniFFI iOS integration; binary (CFE) session persistence
- [x] QUIC / HTTP-3 / gRPC transport engine (H2 fallback on iOS)
- [x] VEIL obfuscation (obfs4 + WebTunnel pluggable transports, opt-in)
- [x] 1:1 messaging, session healing, multi-device linking, account recovery (BIP39)
- [x] Offline delivery — ephemeral per-device Redis-Streams mailbox (no DB persistence, TTL-bounded), drained on reconnect; Redpanda/Kafka bus with 2-phase-commit send; APNs silent-push wake-up
- [x] Voice/video calls (WebRTC + CallKit)
- [x] App-lock (PIN + biometrics, duress PIN)

### In progress / planned
- [ ] Activate hybrid ML-DSA-65 identity signatures on the wire (with smooth migration for existing accounts)
- [ ] Cluster (group) messaging
- [ ] macOS Desktop: route all crypto through EngineAdapter (remove dual crypto path)
- [ ] Android client
- [ ] Japanese localization (共創)

---

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- **Signal Foundation** — Double Ratchet & X3DH
- **RustCrypto** & **Mozilla (UniFFI)** — crypto crates and FFI tooling
- **NIST** — FIPS 203 (ML-KEM) & FIPS 204 (ML-DSA) standardization
