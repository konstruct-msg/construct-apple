# 🔐 Construct Messenger

**Secure end-to-end encrypted messenger with crypto-agility and post-quantum readiness**

[![Rust](https://img.shields.io/badge/Rust-1.75+-orange.svg)](https://www.rust-lang.org/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-red.svg)](https://swift.org/)
[![UniFFI](https://img.shields.io/badge/UniFFI-0.28-blue.svg)](https://mozilla.github.io/uniffi-rs/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 🎯 About the Project

Construct Messenger is a modern **end-to-end encrypted** messenger built on:

- **Double Ratchet Protocol** (Signal Protocol) for forward secrecy
- **X3DH** for asynchronous key agreement
- **Rust Core** for 90% of the cryptographic logic
- **Crypto-Agility** to support various cryptographic algorithms
- **Post-Quantum Ready** architecture for hybrid schemes (Kyber + Dilithium)

### Key Features

- ✅ **100% E2EE** - The server never sees plaintext
- ✅ **Forward Secrecy** - Compromised keys do not reveal history
- ✅ **Crypto-Agility** - Support for multiple cryptographic suites
- ✅ **Zero unsafe** - All Rust code is safe (0 `unsafe` blocks)
- ✅ **Multi-Platform** - Single Rust core for iOS, Android, Web
- ✅ **QR Code Sharing** - Add contacts by scanning QR codes
- ✅ **Offline Message Queue** - Messages saved when offline, sent when reconnected
- ✅ **Privacy-First Profile Sharing** - Display names and avatars shared P2P, not stored on server
- 🚧 **Post-Quantum** - Hybrid schemes (in development)

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Swift UI Layer (iOS)                │
│  - Thin wrapper over Rust                           │
│  - Core Data persistence                            │
│  - WebSocket client                                 │
└───────────────────────┬─────────────────────────────┘
                        │ UniFFI
┌───────────────────────▼─────────────────────────────┐
│              Rust Core (construct-core)             │
│  ✅ Double Ratchet Protocol                         │
│  ✅ X3DH key agreement                              │
│  ✅ Classic Suite (X25519 + Ed25519 + ChaCha20)     │
│  ✅ Crypto-Agility (pluggable crypto providers)     │
│  ✅ MessagePack serialization                       │
│  ✅ Session management                              │
└───────────────────────┬─────────────────────────────┘
                        │ WebSocket + MessagePack
┌───────────────────────▼─────────────────────────────┐
│            Rust Server (Actix + PostgreSQL)         │
│  - Message routing                                  │
│  - Key bundle storage                               │
│  - User authentication                              │
│  - NO access to message content (E2EE)              │
└─────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start

### Requirements

- **Rust** 1.75+ ([rustup](https://rustup.rs/))
- **Xcode** 15+ (for iOS)
- **UniFFI** 0.28

### Building the iOS App

```bash
# 1. Build the Rust library
cd packages/core
cargo build --release --target aarch64-apple-ios

# 2. Generate Swift bindings
uniffi-bindgen generate \
  --library ../../target/aarch64-apple-ios/release/libconstruct_core.a \
  --language swift \
  --out-dir bindings/swift

# 3. Copy to the Xcode project
cp ../../target/aarch64-apple-ios/release/libconstruct_core.a ../../
cp bindings/swift/construct_core.swift ../../ConstructMessenger/
cp bindings/swift/construct_coreFFI.h ../../ConstructMessenger/

# 4. Open Xcode and run
open ../../ConstructMessenger.xcodeproj
```

### Running the Server

```bash
# 1. Set up PostgreSQL
createdb construct_messenger

# 2. Run migrations
cd packages/server
sqlx migrate run

# 3. Start the server
cargo run --release
```

### Using the App

1. **Register** a new account (username + password)
2. **Share your contact:**
   - Go to Settings
   - Tap "Show My QR Code" or "Copy Contact Link"
3. **Add contacts:**
   - From Chats screen, tap "+" → "Scan QR Code"
   - Or paste contact link when adding manually
4. **Start messaging** - all messages are end-to-end encrypted automatically!

**Tip:** Use the camera debug panel (ℹ️ icon in QR scanner) to troubleshoot camera issues.

---

## 📚 Documentation

### Getting Started
- [**ARCHITECTURE_RESPONSIBILITY.md**](docs/ARCHITECTURE_RESPONSIBILITY.md) - 🎯 **Key Principle:** Swift = thin client, Rust = all logic
- [**RUST_SWIFT_INTEGRATION.md**](docs/RUST_SWIFT_INTEGRATION.md) - Complete guide to Rust + Swift integration
- [**XCODE_INTEGRATION.md**](XCODE_INTEGRATION.md) - Setting up the Xcode project
- [**ROADMAP.md**](docs/ROADMAP.md) - Development plan and post-quantum cryptography
- [**TESTING.md**](TESTING.md) - Testing guide

### Feature Documentation
- [**CAMERA_TESTING_GUIDE.md**](docs/CAMERA_TESTING_GUIDE.md) - Camera QR scanner debugging and testing
- [**CONTACT_LINK_FORMAT.md**](docs/CONTACT_LINK_FORMAT.md) - Contact link format and QR code specification
- [**PROFILE_SHARING_IMPLEMENTATION.md**](docs/PROFILE_SHARING_IMPLEMENTATION.md) - Privacy-first profile sharing design

### API
- [**API_V3_SPEC.md**](docs/API_V3_SPEC.md) - API specification with crypto-agility

---

## 🔐 Cryptography

### Classic Suite (v1) - Production

| Component     | Algorithm             | Purpose                         |
|---------------|-----------------------|---------------------------------|
| Key Agreement | **X25519** (ECDH)     | Ephemeral DH for ratcheting     |
| Signatures    | **Ed25519**           | Prekey signatures               |
| AEAD          | **ChaCha20-Poly1305** | Message encryption              |
| KDF           | **HKDF-SHA256**       | Key derivation                  |

### Post-Quantum Hybrid Suite (v2) - In Development

| Component     | Algorithm                | Purpose                         |
|---------------|--------------------------|---------------------------------|
| Key Agreement | **X25519 ⊕ Kyber768**      | Hybrid KEM                      |
| Signatures    | **Ed25519 + Dilithium3**   | Hybrid signatures               |
| AEAD          | **ChaCha20-Poly1305**    | Encryption (unchanged)          |

**Philosophy:** Hybrid = protection against quantum computers + protection against vulnerabilities in new algorithms

---

## 🛠️ Project Structure

```
construct-messenger/
├── docs/                    # 📚 Documentation
│   ├── ARCHITECTURE_RESPONSIBILITY.md
│   ├── API_V3_SPEC.md
│   ├── CAMERA_TESTING_GUIDE.md         # 🆕 Camera debugging
│   ├── CONTACT_LINK_FORMAT.md          # 🆕 QR code format
│   └── PROFILE_SHARING_IMPLEMENTATION.md  # 🆕 P2P profile sharing
│
├── packages/
│   ├── core/               # 🦀 Rust cryptographic core
│   │   ├── src/
│   │   │   ├── crypto/    # Cryptographic modules
│   │   │   │   ├── classic_suite.rs
│   │   │   │   ├── crypto_provider.rs
│   │   │   │   ├── double_ratchet.rs
│   │   │   │   └── x3dh.rs
│   │   │   ├── uniffi_bindings.rs  # UniFFI wrapper
│   │   │   └── construct_core.udl  # UniFFI interface
│   │   ├── Cargo.toml
│   │   └── build.rs
│   │
│   └── server/             # 🦀 Rust WebSocket server
│       ├── src/
│       │   ├── handlers/  # Message handlers
│       │   ├── db.rs      # PostgreSQL
│       │   └── message.rs # Protocol types
│       └── Cargo.toml
│
├── ConstructMessenger/     # 📱 iOS Swift application
│   ├── ViewModels/        # MVVM view models
│   │   ├── ChatViewModel.swift        # 🆕 Queued messages
│   │   └── AuthViewModel.swift
│   ├── Views/             # SwiftUI views
│   │   ├── Chat/
│   │   │   ├── ChatView.swift
│   │   │   ├── MessageBubble.swift    # 🆕 Context menu
│   │   │   └── MessageInfoSheet.swift # 🆕 Message details
│   │   ├── Components/
│   │   │   └── QRScannerView.swift    # 🆕 Camera QR scanner
│   │   └── Settings/
│   │       ├── SettingsView.swift     # 🆕 Quick share
│   │       └── ContactQRCodeView.swift
│   ├── Security/
│   │   └── CryptoManager.swift  # Thin wrapper
│   ├── Networking/
│   │   └── WebSocketManager.swift  # 🆕 Connection checks
│   └── Models/            # Core Data models
│
├── libconstruct_core.a    # Compiled Rust library
└── README.md              # 📖 This file
```

---

## 🧪 Testing

### Rust Core

```bash
cd packages/core
cargo test --all-features
```

### iOS App

```bash
# In Xcode: ⌘U (Run Tests)
```

### Server

```bash
cd packages/server
cargo test
```

---

## 🤝 Contributing

We welcome contributions! Please familiarize yourself with:

1. [ROADMAP.md](docs/ROADMAP.md) - Development plan
2. [RUST_SWIFT_INTEGRATION.md](docs/RUST_SWIFT_INTEGRATION.md) - Technical details
3. Create an Issue to discuss new features
4. Submit a Pull Request

### Priority Areas

- 🔴 **Critical:** Complete profile sharing implementation
- 🟠 **Important:** Enhanced message delivery status (seen/read receipts)
- 🟡 **Useful:** UI/UX polish (toast notifications, loading states)
- 🟢 **Future:** Post-quantum crypto implementation, group messaging

---

## 📊 Current Status

**Version:** v0.2.8 (Alpha)
**Date:** January 1, 2026

### 🆕 Recent Updates (v0.3.0)

**Messaging Improvements:**
- Fixed session initialization for new contacts - no more "Initializing secure connection..." hang
- Added offline message queue - messages saved when disconnected, auto-sent when reconnected
- Message context menu with copy, reply, delete, and detailed info
- Visual status indicators: Sending → Sent → Delivered

**Contact Management:**
- QR code scanner with camera permission handling
- Debug panel for troubleshooting camera issues (tap ℹ️ icon)
- Test mode for simulator (auto-generates mock QR scans)
- Simplified contact sharing - moved to main Settings screen

**Developer Experience:**
- Comprehensive debug logging for session initialization
- Camera testing guide with troubleshooting steps
- Profile sharing design documentation

### ✅ Done
- [x] Rust cryptographic core (Double Ratchet + X3DH)
- [x] UniFFI integration with iOS
- [x] WebSocket server with PostgreSQL
- [x] SwiftUI interface with Core Data
- [x] QR code scanning for contact addition
- [x] Camera permission handling and debugging tools
- [x] Offline message queue with auto-retry
- [x] Message context menu (copy, reply, delete, info)
- [x] Improved session initialization and error handling
- [x] Settings redesign with quick contact sharing

### 🔨 In Progress
- [ ] Profile sharing implementation (display names & avatars)
- [ ] Message delivery status indicators
- [ ] Enhanced error feedback and toast notifications

### 📅 Planned
**Q2 2026:**
- [ ] Post-quantum hybrid cryptography (Kyber768 + Dilithium3)
- [ ] Web PWA
- [ ] Group messaging (Sender Keys)
- [ ] Voice/Video calls (WebRTC)
- [ ] **Server Federation** (Email 2.0 with E2E encryption)
- [ ] Decentralized architecture (alice@server1.com ↔ bob@server2.com)
- [ ] DNS-based server discovery
- [ ] Sealed sender for metadata privacy

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details

---

## 🙏 Acknowledgments

- **Signal Foundation** for the Double Ratchet Protocol
- **Mozilla** for UniFFI
- **Rust Community** for excellent crypto libraries
- **NIST** for standardizing post-quantum cryptography
