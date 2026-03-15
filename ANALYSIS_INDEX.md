# Construct Core FFI Architecture Analysis - Complete Index

## Documents in This Analysis

### 1. **FFI_QUICK_REFERENCE.txt** ⚡ START HERE
- Complete list of all FFI functions grouped by domain
- State management architecture overview (1-pager)
- What's missing for Session Coordinator
- Implementation roadmap with phases

**Use this when you need:**
- Quick lookup of a specific FFI function
- High-level understanding of current architecture
- Scope of changes needed

---

### 2. **RUST_CORE_FFI_ANALYSIS.md** 📚 DETAILED REFERENCE
- **Section 1:** Complete FFI functions with parameters and return types
- **Section 2:** Deep dive into state management architecture
  - Per-instance ClassicCryptoCore structure
  - Internal Client state (sessions HashMap, OTPK tracking)
  - Persistence model (Keychain ↔ in-memory)
  - Global Config singleton
- **Section 3:** Callback mechanisms (UniFFI PowProgressCallback)
  - How Swift ↔ Rust callbacks work
  - Thread-safe trait patterns
- **Section 4:** Architectural changes needed for Session Coordinator
  - Gap analysis vs. stateless current design
  - 7 concrete design patterns for the coordinator
    1. Session Event Callbacks (UDL)
    2. Session Lifecycle Management
    3. Thread-Safe Delegate Pattern
    4. Lifecycle Tracking & Expiration
    5. Multi-Device Coordination
    6. Storage Coordinator Integration
    7. Ratchet Event Tracking
  - Full Rust code examples for each pattern
- **Section 5:** Implementation roadmap with phases

**Use this when you need:**
- Deep understanding of how state currently works
- Learn the thread-safety patterns used
- Reference code for designing the coordinator
- Understand persistence flow

---

### 3. **IMPLEMENTATION_EXAMPLES.md** 💻 CODE TEMPLATES
- **Section 1:** Complete SessionCoordinator Rust implementation
  - UDL definition (callbacks + interface)
  - Full Rust code with metadata tracking
  - Callback firing on session events
- **Section 2:** Swift usage examples
  - SessionDelegate implementation
  - Basic send/receive flow
  - Lifecycle management from Swift
- **Section 3:** Storage integration pattern
  - SessionStore trait abstraction
  - Auto-save/restore on session lifecycle
  - Full implementation example
- **Section 4:** Multi-device coordinator
  - DeviceCoordinator struct
  - GlobalDelegate for cross-device events
  - Message routing pattern
- **Section 5:** Full application integration
  - Complete ConstructMessenger class
  - Session restoration on app startup
  - Background/foreground lifecycle hooks

**Use this when you need:**
- Copy-paste templates to implement
- See full end-to-end flow examples
- Understand how to integrate coordinator into app

---

## Key Findings Summary

### ✅ What Currently Exists

1. **Stateless API** — Each function is independent
   - No global singleton (except Config)
   - Per-instance state via Arc<Mutex<>>
   - No callbacks except PoW progress

2. **Thread-Safe Foundation**
   - Arc + Mutex pattern for shared ownership
   - Send + Sync trait bounds for callbacks
   - OnceLock for Config singleton

3. **Comprehensive Crypto Primitives**
   - X3DH handshake + Double Ratchet messaging
   - Post-quantum ML-KEM-768 support
   - Traffic protection (cover traffic, timing)
   - Account recovery (BIP39 + SLIP-0010)
   - Device authentication (PoW)

4. **Session Persistence**
   - Export/import sessions as JSON
   - Export/import private keys as JSON
   - Export/import one-time prekeys as JSON
   - **BUT:** No automatic persistence layer

### ❌ What's Missing for Session Coordinator

1. **Event Callbacks** — No way to notify app of session state changes
2. **Lifecycle Tracking** — No created_at, last_activity, expiration
3. **Storage Integration** — No automatic save/restore on state changes
4. **Multi-Device** — No coordination across devices
5. **Ratchet Events** — No notification of key ratchets or OTPK consumption

### 🎯 Implementation Path

| Phase | Components | Effort | Duration |
|-------|-----------|--------|----------|
| 1 | Add SessionCoordinatorDelegate + callbacks | Low | 1-2 days |
| 2 | Add lifecycle tracking (timestamps, status) | Low | 1-2 days |
| 3 | Integrate persistent storage (SessionStore trait) | Medium | 3-4 days |
| 4 | Multi-device coordinator wrapper | Medium | 3-4 days |
| 5 | Advanced tracking (ratchets, metrics) | Low | 1-2 days |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Swift/Kotlin Layer                        │
│  • App UI logic                                              │
│  • User interactions                                         │
│  • Storage (Keychain, IndexedDB)                             │
└─────────────────────────────────────┬───────────────────────┘
                                       │
                          UniFFI FFI Boundary
                                       │
                                       ↓
┌─────────────────────────────────────────────────────────────┐
│            Construct Core Rust (This Analysis)               │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ SessionCoordinator (TO BE ADDED)                       │ │
│  │  • Delegate callbacks (session create/expire/ratchet)  │ │
│  │  • Lifecycle tracking (created_at, last_activity)      │ │
│  │  • Storage integration (auto-save/restore)             │ │
│  │  • Multi-device coordination                           │ │
│  └─────────────────────────┬─────────────────────────────┘ │
│                            │                                │
│  ┌─────────────────────────┴─────────────────────────────┐ │
│  │ ClassicCryptoCore (EXISTING)                           │ │
│  │  • Arc<Mutex<ClassicClient>>                           │ │
│  │  • KeyManager (identity, SPK, signing keys)            │ │
│  │  • Sessions HashMap<contact_id, Session>              │ │
│  │  • OTPK tracking HashMap<contact_id, otpk_id>         │ │
│  └─────────────────────────┬─────────────────────────────┘ │
│                            │                                │
│  ┌─────────────────────────┴─────────────────────────────┐ │
│  │ Crypto Primitives (EXISTING)                           │ │
│  │  • X3DH Handshake                                       │ │
│  │  • Double Ratchet Messaging                            │ │
│  │  • ML-KEM-768 (Post-Quantum)                           │ │
│  │  • Traffic Protection                                  │ │
│  │  • BIP39 Recovery                                      │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ Config (OnceLock Singleton, EXISTING)                  │ │
│  │  • Suite IDs, nonce lengths, iteration counts         │ │
│  │  • NO session or user state                           │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## Important Notes

### Thread Safety
- All types implement `Send + Sync`
- Interior mutability via `Mutex` (synchronous locking)
- UniFFI automatically wraps returned types in `Arc<>`
- No poisoned locks (uses `unwrap_or_else(|p| p.into_inner())`)

### State Persistence
- **Current:** JSON export/import only, NO automatic persistence
- **Sessions:** Must call `export_session_json()` explicitly to Keychain
- **Private keys:** Must call `export_private_keys_json()` explicitly
- **OTPKs:** Must call `export_one_time_prekeys_json()` explicitly
- **Gap:** No automatic sync when state changes

### Callback Capabilities
- ✅ Can implement Swift callbacks that Rust calls during operations
- ❌ Cannot implement Rust callbacks that Swift calls (one-way only)
- ✅ Callbacks are synchronous (block during operation)
- ✅ Callbacks are thread-safe (Send + Sync required)

### Performance Considerations
- Mutex locking on every operation (no RwLock yet)
- HashMap lookups are O(1) per session
- Session count could impact performance if very large (1000s)
- Consider RwLock for read-heavy operations (decrypt is read-only)

---

## Next Steps for Implementation

1. **Review** `FFI_QUICK_REFERENCE.txt` for 5-minute overview
2. **Study** `RUST_CORE_FFI_ANALYSIS.md` Section 2 & 3 to understand state management
3. **Review** `RUST_CORE_FFI_ANALYSIS.md` Section 4 for design patterns
4. **Copy** relevant code from `IMPLEMENTATION_EXAMPLES.md` as starting point
5. **Add to UDL** the new SessionCoordinator callback interface
6. **Implement** phase by phase, starting with Phase 1 (callbacks)
7. **Test** with the examples in IMPLEMENTATION_EXAMPLES.md

---

## File Locations

All analysis documents are in:
```
/Users/maximeliseyev/Code/construct-messenger/
├── FFI_QUICK_REFERENCE.txt              ⚡ Start here
├── RUST_CORE_FFI_ANALYSIS.md            📚 Reference
├── IMPLEMENTATION_EXAMPLES.md           💻 Code templates
└── ANALYSIS_INDEX.md                    📋 This file
```

Source code reference:
```
/Users/maximeliseyev/Code/construct-core/
├── src/construct_core.udl              🔧 UDL interface definition
├── src/uniffi_bindings.rs              🔧 FFI implementation
├── src/lib.rs                          🔧 Module structure
├── src/crypto/client_api.rs            🔧 Client implementation
├── src/crypto/session_api.rs           🔧 Session implementation
├── src/config.rs                       🔧 Config singleton
└── src/pow.rs                          🔧 PoW callback example
```

