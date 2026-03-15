# Construct Core Rust FFI Surface & Architecture Analysis

## 1. COMPLETE FFI FUNCTIONS EXPOSED (from construct_core.udl)

### Device-Based Authentication (Namespace Functions)
```
device_id
  ├── derive_device_id(identity_public_key: sequence<u8>) -> string
  └── format_federated_id(device_id: string, server_hostname: string) -> string

pow
  ├── compute_pow(challenge: string, difficulty: u32) -> PowSolution
  ├── compute_pow_with_progress(challenge, difficulty, progress_callback?) -> PowSolution
  └── verify_pow(challenge, solution, required_difficulty) -> boolean
```

### Cryptographic Core (ClassicCryptoCore Interface)
**Factory Functions:**
- `create_crypto_core() -> Arc<ClassicCryptoCore>` — NEW instance
- `create_crypto_core_from_keys_json(keys_json: string) -> Arc<ClassicCryptoCore>` — FROM PERSISTENCE

**Key & Bundle Management:**
- `export_registration_bundle_json() -> string` — Pubkey bundle for registration
- `sign_bundle_data(bundle_data_json: sequence<u8>) -> string` — Sign with Ed25519
- `export_private_keys_json() -> string` — Export to Keychain (SECURITY!)
- `set_local_user_id(user_id: string) -> void` — Store user UUID

**Session Initialization (Handshake):**
- `init_session(contact_id: string, recipient_bundle: sequence<u8>) -> string` — SENDER-side X3DH
- `init_receiving_session(contact_id, recipient_bundle, first_message) -> SessionInitResult` — RECEIVER-side X3DH

**Messaging (Double Ratchet):**
- `encrypt_message(session_id: string, plaintext: string) -> EncryptedMessageComponents`
- `decrypt_message(session_id, ephemeral_public_key, message_number, content) -> string`

**Session Management:**
- `export_session_json(contact_id: string) -> string` — Serialize to Keychain
- `import_session_json(contact_id, session_json: string) -> string` — Restore from Keychain
- `get_all_session_contact_ids() -> sequence<string>` — List active sessions
- `remove_session(contact_id: string) -> boolean` — Delete session

**One-Time Prekeys (X3DH):**
- `generate_one_time_prekeys(count: u32) -> sequence<OtpkPair>` — Batch generate
- `prekeys_available_count() -> u32` — Query available count
- `one_time_prekey_count() -> u32` — Total count
- `export_one_time_prekeys_json() -> string` — Serialize to Keychain
- `import_one_time_prekeys_json(json: string) -> void` — Restore from Keychain

**Key Rotation:**
- `rotate_signed_prekey() -> RotatedSpkBundle` — Atomic rotation

**Post-Quantum Support:**
- `apply_pq_contribution(contact_id: string, kem_shared_secret: sequence<u8>) -> void` — Mix in ML-KEM shared secret

### Invite Crypto (Namespace Functions - Dynamic Invites)
```
ephemeral_keys
  ├── generate_ephemeral_keypair() -> EphemeralKeyPair
  ├── sign_invite_data(data: string, identity_secret_key: sequence<u8>) -> InviteSignature
  ├── verify_invite_signature(data, signature, verifying_key) -> boolean
  └── derive_verifying_key_from_secret(identity_secret_key) -> sequence<u8>
```

### Account Recovery (Namespace Functions - BIP39 + SLIP-0010)
```
recovery
  ├── generate_mnemonic(word_count: u8) -> string
  ├── validate_mnemonic(mnemonic: string) -> boolean
  ├── mnemonic_to_seed(mnemonic: string) -> sequence<u8>
  ├── derive_recovery_keypair(seed: sequence<u8>) -> RecoveryKeypair
  ├── sign_recovery_challenge(private_key, message) -> sequence<u8>
  └── verify_recovery_signature(public_key, message, signature) -> boolean
```

### Traffic Protection (Namespace + Interface)
**Namespace Functions:**
```
traffic
  ├── generate_dummy_message(size: u64) -> sequence<u8>
  ├── is_dummy_message(data: sequence<u8>) -> boolean
  ├── jittered_interval_ms(base_ms, jitter_ms) -> u64
  ├── random_send_delay_ms(max_delay_ms) -> u64
  ├── heartbeat_interval_ms(base_interval_sec) -> u64
  ├── battery_aware_jitter_ms(base_ms, max_jitter_ms, battery_level) -> u64
  └── recommended_send_delay_ms(is_high_priority, battery_level) -> u64
```

**TrafficProtectionManager Interface:**
```
TrafficProtectionManager {
  constructor(CoverTrafficConfig config)
  + update_battery_level(float level) -> void
  + record_real_message_sent() -> void
  + should_send_dummy() -> boolean
  + generate_dummy() -> sequence<u8>
  + get_metrics() -> EnergyMetrics
  + reset_metrics() -> void
  + current_interval_ms() -> u64
  + is_currently_active() -> boolean
}
```

### Post-Quantum KEM (ML-KEM-768, Namespace Functions)
```
pq_kem
  ├── mlkem768_keygen() -> MLKEMKeyPair (public: 1184B, secret: 2400B)
  ├── mlkem768_encapsulate(public_key: sequence<u8>) -> MLKEMEncapsulation
  └── mlkem768_decapsulate(secret_key, ciphertext) -> sequence<u8> (shared_secret)
```

---

## 2. STATE MANAGEMENT ARCHITECTURE IN RUST

### **Current Architecture: PER-INSTANCE STATE (No Global Singleton)**

#### ClassicCryptoCore Structure:
```rust
pub struct ClassicCryptoCore {
    inner: Mutex<ClassicClient<ClassicSuiteProvider>>,
}

// UniFFI wraps this in Arc<> automatically
pub fn create_crypto_core() -> Result<Arc<ClassicCryptoCore>, CryptoError> {
    Ok(Arc::new(ClassicCryptoCore {
        inner: Mutex::new(client),
    }))
}
```

**Key characteristics:**
- **No global singleton** — Each call to `create_crypto_core()` creates a NEW independent instance
- **Arc<Mutex<>>** wrapping — Thread-safe shared ownership + interior mutability
  - `Arc` = automatic reference counting (managed by UniFFI)
  - `Mutex` = synchronous locking for thread safety
- **Per-device state** — Each device/app gets its own `ClassicCryptoCore`

#### Internal Client Structure (ClassicClient):
```rust
pub struct Client<P: CryptoProvider, H: KeyAgreement<P>, M: SecureMessaging<P>> {
    key_manager: KeyManager<P>,                    // Long-term keys (identity, SPK, signing)
    sessions: HashMap<String, Session<P, H, M>>,  // All active sessions keyed by contact_id
    pending_otpk_ids: HashMap<String, u32>,       // OTPK IDs for first message per contact
    local_user_id: String,                        // User UUID from server
}
```

**Session Storage:**
- **In-memory HashMap**: `HashMap<contact_id, Session>` 
- **Lookup by contact_id** (NOT random UUID) — Swift expects contact_id as session_id
- **No persistence** — Sessions MUST be exported/imported via JSON

#### Persistence Model:
```
┌─────────────────────────────────────────┐
│  iOS Keychain / IndexedDB (Encrypted)   │
│  • Private keys (export_private_keys)   │
│  • Sessions (export_session_json)       │
│  • One-time prekeys (export_otpk_json)  │
└─────────────────┬───────────────────────┘
                  │
              JSON ↓ export/import
┌─────────────────────────────────────────┐
│  Rust Core Memory (Unencrypted)         │
│  • ClassicCryptoCore::inner             │
│    └─ ClassicClient                     │
│      ├─ KeyManager                      │
│      ├─ HashMap<contact_id, Session>    │
│      └─ HashMap<contact_id, otpk_id>    │
└─────────────────────────────────────────┘
```

### **Global State (Config Singleton Only)**
```rust
// src/config.rs
static GLOBAL_CONFIG: OnceLock<Config> = OnceLock::new();

impl Config {
    pub fn global() -> &'static Config {
        GLOBAL_CONFIG.get_or_init(Config::default)
    }
    pub fn init() -> Result<(), &'static str> { ... }
    pub fn init_from_env() -> Result<(), &'static str> { ... }
}

// Usage in uniffi_bindings.rs:
pub fn create_crypto_core() -> Result<Arc<ClassicCryptoCore>, CryptoError> {
    let _ = crate::config::Config::init();  // One-time init
    // ... create instance
}
```

**Config contains only:**
- Cryptographic parameters (PBKDF2 iterations, nonce lengths)
- Double Ratchet limits (max_skipped_messages)
- Suite IDs (classic_suite_id = 1)
- Validation rules (username min/max length)
- No session or user state

---

## 3. CALLBACK/DELEGATE MECHANISMS IN UNIFFI

### **UniFFI Callback Interface: PowProgressCallback**

```rust
// From UDL:
callback interface PowProgressCallback {
    void on_progress(u64 current_nonce, u64 attempts, f32 estimated_progress);
};

// Rust trait:
pub trait PowProgressCallback: Send + Sync {
    fn on_progress(&self, current_nonce: u64, attempts: u64, estimated_progress: f32);
}

// UniFFI FFI function accepts it:
pub fn compute_pow_with_progress(
    challenge: String,
    difficulty: u32,
    progress_callback: Option<Box<dyn PowProgressCallback>>,
) -> PowSolution {
    crate::pow::compute_pow_with_progress(&challenge, difficulty, progress_callback)
}
```

**How it works in Rust:**
```rust
pub fn compute_pow_with_progress(
    challenge: &str,
    difficulty: u32,
    progress_callback: Option<Box<dyn PowProgressCallback>>,
) -> PowSolution {
    loop {
        // ... compute hash ...
        if let Some(cb) = &progress_callback {
            cb.on_progress(nonce, attempts, estimated_progress);
        }
    }
}
```

### **Swift ↔ Rust Callback Flow:**

```swift
// Swift side:
class MyPowCallback: PowProgressCallback {
    func onProgress(currentNonce: UInt64, attempts: UInt64, estimatedProgress: Float) {
        print("Progress: \(estimatedProgress)%")
    }
}

let solution = try constructCore.computePowWithProgress(
    challenge: "challenge_xyz",
    difficulty: 4,
    progressCallback: MyPowCallback()
)
```

### **Callback Characteristics:**
- ✅ **One-way** — Swift → Rust (Rust calls Swift methods)
- ✅ **Synchronous** — Blocks during computation
- ⚠️ **Not persistent** — Only for single operation lifetime
- ⚠️ **Limited** — Only one callback interface (PowProgressCallback)
- ❌ **No session-level callbacks** — Can't notify on new messages, session changes, etc.

---

## 4. CHANGES NEEDED FOR "SESSION COORDINATOR" IN RUST

### **Current Gap: Stateless API → Stateful Coordinator**

**Current Design (Stateless from Swift's POV):**
```swift
// Swift creates and owns the CryptoCore instance
let cryptoCore = try constructCore.createCryptoCore()

// Swift passes all parameters explicitly
try cryptoCore.initSession(contactId: "bob", recipientBundle: bobBundle)
let encrypted = try cryptoCore.encryptMessage(sessionId: "bob", plaintext: "Hi")
```

**What Session Coordinator Needs:**
```rust
// Pseudo-code of desired architecture
pub struct SessionCoordinator {
    crypto_core: Arc<ClassicCryptoCore>,
    // Callbacks for session events
    on_session_created: Option<Box<dyn Fn(&str) + Send + Sync>>,
    on_session_expired: Option<Box<dyn Fn(&str) + Send + Sync>>,
    on_message_received: Option<Box<dyn Fn(&str, &str) + Send + Sync>>,  // contact_id, plaintext
}

pub trait SessionCoordinatorDelegate: Send + Sync {
    fn on_session_created(&self, contact_id: &str);
    fn on_session_expired(&self, contact_id: &str);
    fn on_ratchet_forward(&self, contact_id: &str, message_number: u32);
}
```

### **Architectural Changes Required:**

#### **1. Add Session Event Callbacks (UDL)**
```udl
callback interface SessionCoordinatorDelegate {
    void on_session_created(string contact_id);
    void on_session_expired(string contact_id);
    void on_key_ratchet(string contact_id, u32 message_number);
    void on_otpk_consumed(string contact_id, u32 key_id);
};

interface SessionCoordinator {
    constructor(ClassicCryptoCore crypto_core, SessionCoordinatorDelegate? delegate);
    void set_delegate(SessionCoordinatorDelegate? delegate);
    string init_session(string contact_id, sequence<u8> recipient_bundle);
    // ... other methods ...
};
```

#### **2. Session Lifecycle Management**
```rust
pub struct SessionCoordinator {
    inner: Mutex<SessionCoordinatorInner>,
}

struct SessionCoordinatorInner {
    crypto_core: Arc<ClassicCryptoCore>,
    active_sessions: HashSet<String>,  // Tracks which sessions exist
    delegate: Option<Box<dyn SessionCoordinatorDelegate>>,
    session_created_at: HashMap<String, SystemTime>,
    last_activity: HashMap<String, SystemTime>,
}

impl SessionCoordinator {
    pub fn init_session(&self, contact_id: &str, bundle: &[u8]) -> Result<String, Error> {
        let session_id = {
            let mut inner = self.inner.lock().unwrap();
            let session_id = inner.crypto_core.init_session(contact_id, bundle)?;
            inner.active_sessions.insert(session_id.clone());
            inner.session_created_at.insert(session_id.clone(), SystemTime::now());
            if let Some(delegate) = &inner.delegate {
                delegate.on_session_created(&session_id);
            }
            session_id
        };
        Ok(session_id)
    }
}
```

#### **3. Thread-Safe Delegate Pattern**
```rust
// Current pattern (PoW callback):
pub trait PowProgressCallback: Send + Sync {
    fn on_progress(&self, current_nonce: u64, attempts: u64, estimated_progress: f32);
}

// Same pattern for SessionCoordinatorDelegate:
pub trait SessionCoordinatorDelegate: Send + Sync {
    fn on_session_created(&self, contact_id: &str);
    fn on_session_expired(&self, contact_id: &str);
    fn on_key_ratchet(&self, contact_id: &str, message_number: u32);
}
```

#### **4. Lifecycle Tracking**
```rust
pub struct SessionLifecycle {
    pub contact_id: String,
    pub created_at: SystemTime,
    pub last_activity: SystemTime,
    pub message_count: u32,
    pub status: SessionStatus,
}

pub enum SessionStatus {
    Active,
    Idle(Duration),          // No activity for N seconds
    Expired,
    PendingRekeyDue,
}

impl SessionCoordinator {
    pub fn cleanup_expired_sessions(&self, max_idle_secs: u64) -> Vec<String> {
        let mut inner = self.inner.lock().unwrap();
        let now = SystemTime::now();
        let mut expired = Vec::new();
        
        for (contact_id, last_activity) in &inner.last_activity {
            if let Ok(elapsed) = now.duration_since(*last_activity) {
                if elapsed.as_secs() > max_idle_secs {
                    inner.crypto_core.remove_session(contact_id);
                    if let Some(delegate) = &inner.delegate {
                        delegate.on_session_expired(contact_id);
                    }
                    expired.push(contact_id.clone());
                }
            }
        }
        for id in &expired {
            inner.active_sessions.remove(id);
            inner.last_activity.remove(id);
        }
        expired
    }
}
```

#### **5. Multi-Device Coordination**
```rust
pub struct DeviceCoordinator {
    device_id: String,
    crypto_cores: HashMap<String, Arc<ClassicCryptoCore>>,  // Per-device instances
    session_coordinators: HashMap<String, Arc<SessionCoordinator>>,
    global_delegate: Arc<Mutex<Option<Box<dyn GlobalDelegate>>>>,
}

pub trait GlobalDelegate: Send + Sync {
    fn on_device_message(&self, device_id: &str, contact_id: &str, plaintext: &str);
    fn on_device_session_created(&self, device_id: &str, contact_id: &str);
}
```

#### **6. Storage Coordinator Integration**
```rust
pub struct StorageCoordinator {
    sessions_storage: Arc<dyn SessionStore>,  // Trait for Keychain/DB
    crypto_core: Arc<ClassicCryptoCore>,
    session_coordinator: Arc<SessionCoordinator>,
}

pub trait SessionStore: Send + Sync {
    fn save_session(&self, contact_id: &str, session_json: &str) -> Result<()>;
    fn load_session(&self, contact_id: &str) -> Result<String>;
    fn list_sessions(&self) -> Result<Vec<String>>;
    fn delete_session(&self, contact_id: &str) -> Result<()>;
}

// Auto-sync on changes:
impl SessionCoordinator {
    pub fn init_session_with_storage(
        &self,
        contact_id: &str,
        bundle: &[u8],
        storage: &dyn SessionStore,
    ) -> Result<String, Error> {
        let session_id = self.init_session(contact_id, bundle)?;
        
        // Auto-save after creation
        let crypto_core = self.inner.lock().unwrap().crypto_core.clone();
        let session_json = crypto_core.export_session_json(contact_id)?;
        storage.save_session(contact_id, &session_json)?;
        
        Ok(session_id)
    }
}
```

#### **7. Ratchet Event Tracking**
```rust
pub trait RatchetCallback: Send + Sync {
    fn on_dh_ratchet(&self, contact_id: &str, direction: RatchetDirection, new_key_id: u32);
    fn on_chain_key_advanced(&self, contact_id: &str, steps: u32);
}

pub enum RatchetDirection {
    Send,   // Our DH private key advanced
    Receive, // Received new ephemeral, advanced DH
}

// Hook into DoubleRatchetSession:
impl SessionCoordinator {
    pub fn encrypt_message_with_tracking(
        &self,
        session_id: &str,
        plaintext: &str,
        ratchet_cb: &dyn RatchetCallback,
    ) -> Result<EncryptedMessageComponents, Error> {
        let mut inner = self.inner.lock().unwrap();
        let result = inner.crypto_core.encrypt_message(session_id, plaintext)?;
        
        // Track that message_number changed (implies DH ratchet)
        if result.message_number == 0 {
            ratchet_cb.on_dh_ratchet(session_id, RatchetDirection::Send, 0);
        }
        
        Ok(result)
    }
}
```

---

## 5. SUMMARY TABLE: WHAT EXISTS VS WHAT'S NEEDED

| Component | Current | Needed for Coordinator |
|-----------|---------|------------------------|
| **State Container** | Arc<Mutex<ClassicCryptoCore>> per instance | SessionCoordinator wrapper + lifecycle tracking |
| **Session Storage** | HashMap<contact_id, Session> in-memory | + Persistent store integration + cleanup |
| **Callbacks** | Only PowProgressCallback (PoW only) | SessionCoordinatorDelegate + RatchetCallback + GlobalDelegate |
| **Event Notifications** | None | On session create/expire/ratchet/OTPK consume |
| **Multi-Device** | No coordination | DeviceCoordinator + device-level delegate |
| **Lifecycle** | Sessions never expire | Idle timeout + explicit cleanup |
| **Config** | OnceLock<Config> global | Keep as-is |
| **Thread Safety** | Arc + Mutex + Send + Sync | + RwLock for read-heavy operations? |

---

## 6. RECOMMENDED IMPLEMENTATION ORDER

### **Phase 1: Add Session Callbacks**
- Add `SessionCoordinatorDelegate` UDL + Rust trait
- Create `SessionCoordinator` struct wrapper
- Add `set_delegate()` method
- Hook callbacks in init_session / encrypt_message / decrypt_message

### **Phase 2: Lifecycle Management**
- Track `created_at`, `last_activity` per session
- Add `cleanup_expired_sessions(max_idle_secs)` method
- Add session status tracking (Active, Idle, Expired)

### **Phase 3: Storage Integration**
- Abstract storage layer (SessionStore trait)
- Auto-save on init_session / after decrypt
- Auto-load on startup

### **Phase 4: Multi-Device Coordination**
- Add `DeviceCoordinator` for managing multiple devices
- Cross-device message relay (if needed by app architecture)

### **Phase 5: Advanced Tracking**
- Ratchet event callbacks
- OTPK consumption tracking
- Message ordering guarantees

---

