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

**Note:** Ядро `construct-core` теперь находится в отдельном репозитории `~/Code/construct-core/`.

```bash
# 1. Generate Swift bindings (автоматически находит ~/Code/construct-core)
./generate_swift_bindings.sh

# 2. Open Xcode and run
open ConstructMessenger.xcodeproj
```

Скрипт `generate_swift_bindings.sh` автоматически:
- Находит ядро в `~/Code/construct-core/`
- Собирает библиотеку для нужных архитектур
- Генерирует Swift биндинги в `ConstructMessenger/`

### Running the Server

**Note:** Сервер находится в отдельном репозитории. См. документацию сервера для инструкций по запуску.

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

### X3DH Prologue Format

Для защиты от **key substitution attacks** (атак подмены ключей между разными криптографическими наборами), подпись `signed_prekey` включает **prologue** по аналогии с Noise Protocol.

**Формат prologue:**
```
Prologue = "X3DH" (4 bytes) || suite_id (2 bytes, little-endian)
```

**Примеры:**
- Suite ID 1 (CLASSIC): `[0x58, 0x33, 0x44, 0x48, 0x01, 0x00]` = `"X3DH" || 0x0001`
- Suite ID 2 (PQ_HYBRID): `[0x58, 0x33, 0x44, 0x48, 0x02, 0x00]` = `"X3DH" || 0x0002`

**Процесс подписания:**
1. Клиент генерирует `signed_prekey_public`
2. Создаёт prologue: `"X3DH" || suite_id`
3. Подписывает: `sign(prologue || signed_prekey_public)`
4. Отправляет bundle на сервер

**Процесс проверки:**
1. Клиент получает bundle с `suite_id`
2. Строит prologue из `suite_id` из bundle
3. Проверяет подпись: `verify(prologue || signed_prekey_public, signature)`
4. **Backward compatibility:** Если новый формат не проходит, пробует старый (без prologue)

**Важно для сервера:**
- Сервер **НЕ** должен знать о prologue
- Сервер работает только с непрозрачными данными (opaque blobs)
- Сервер **НЕ** проверяет подпись (это делает клиент)
- Сервер должен хранить `suite_id` для логирования/статистики

---

## 🛠️ Project Structure

**Note:** Ядро `construct-core` находится в отдельном репозитории `~/Code/construct-core/`.

```
construct-messenger/
│
├── ConstructMessenger/     # 📱 iOS Swift application
│   ├── ViewModels/        # MVVM view models
│   ├── Views/             # SwiftUI views
│   ├── Security/
│   │   └── CryptoManager.swift  # UniFFI wrapper around construct-core
│   ├── Networking/
│   │   └── WebSocketManager.swift
│   ├── Models/            # Core Data models
│   ├── construct_core.swift      # Generated Swift bindings
│   └── construct_coreFFI.h       # Generated C header
│
├── generate_swift_bindings.sh    # Script to generate Swift bindings
└── README.md                     # 📖 This file
```

---

## 🧪 Testing

### Rust Core

Ядро тестируется в репозитории `~/Code/construct-core/`:

```bash
cd ~/Code/construct-core
cargo test --all-features
```

### iOS App

```bash
# In Xcode: ⌘U (Run Tests)
```

---

## 🤝 Contributing

We welcome contributions! Please familiarize yourself with:

1. Create an Issue to discuss new features
2. Submit a Pull Request

### Priority Areas

- 🔴 **Critical:** Fix message decryption
- 🟠 **Important:** Unit/integration tests
- 🟡 **Useful:** UI/UX improvements
- 🟢 **Future:** Post-quantum crypto implementation

---

## 📊 Current Status

**Version:** v0.2.8 (Early Alpha)
**Date:** December 26, 2025

### ✅ Done
- [x] Rust cryptographic core (Double Ratchet + X3DH)
- [x] UniFFI integration with iOS
- [x] WebSocket server with PostgreSQL
- [x] Basic UI (SwiftUI)
- [x] Core Data persistence
- [x] Reactive architecture with Combine (Phase 2)


### 📅 Planned
**Q1 2026:**
- [ ] **Offline Message Queue** - Retry failed messages with exponential backoff
- [ ] **APNs Push Notifications** - 98% reduction in network requests, massive battery savings
- [ ] **State Machine Architecture** (Phase 3) - See [docs/architecture/state-machine-migration.md](docs/architecture/state-machine-migration.md)
  - Explicit state modeling for auth and polling
  - Offline mode support
  - Reconnection with exponential backoff
  - Better error handling and debugging

**Q2 2026:**
- [ ] **Privacy & Traffic Obfuscation** - See [docs/architecture/improvement-roadmap.md](docs/architecture/improvement-roadmap.md)
  - Message size padding
  - Timing obfuscation
  - Dummy traffic (opt-in)
- [ ] Post-quantum hybrid cryptography (Kyber768 + Dilithium3)
- [ ] Web PWA
- [ ] Group messaging (Sender Keys)
- [ ] Voice/Video calls (WebRTC)

**Q3 2026:**
- [ ] **Server Federation** (Email 2.0 with E2E encryption)
- [ ] Decentralized architecture (alice@server1.com ↔ bob@server2.com)
- [ ] DNS-based server discovery
- [ ] Sealed sender for metadata privacy

**Future Considerations:**
- [ ] WebSocket support (opt-in, beta) - See roadmap for scaling strategy

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details

---

## 🙏 Acknowledgments

- **Signal Foundation** for the Double Ratchet Protocol
- **Mozilla** for UniFFI
- **Rust Community** for excellent crypto libraries
- **NIST** for standardizing post-quantum cryptography
