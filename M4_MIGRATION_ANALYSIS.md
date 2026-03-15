# M4 Migration Analysis: Crypto Manager Architecture

## EXECUTIVE SUMMARY

**Key Finding**: CryptoManager is a **thin Swift orchestration layer** around ClassicCryptoCore (Rust). Most of the complex logic is already in Rust. The Swift code primarily handles:
1. **State persistence** (Keychain/UserDefaults)
2. **Session lifecycle management** (in-memory + archive fallback)
3. **PQC ceremony** (PQXDH encapsulation/decapsulation orchestration)
4. **Recovery workflows** (archived session restoration)

**Migration Strategy**: OrchestratorCore in Rust should absorb the session state machine + archive logic. Keychain operations must remain in Swift (platform dependency).

---

## 1. CRYPTOMANAGER.SWIFT (808 lines)

### Instance Variables / Stored Properties

| Property | Type | Storage | Purpose |
|----------|------|---------|---------|
| `core` | `ClassicCryptoCore?` | Memory (Rust Arc) | Main Rust crypto engine |
| `coreProvider` | `CryptoCoreProvider` | Memory | Loads/saves core from Keychain |
| `sessionStore` | `SessionStore` | Memory (in-process) | Maps userId→sessionId |
| `archiveManager` | `SessionArchiveManager` | Memory + Keychain | Fallback archived sessions |
| `messageCrypto` | `MessageCryptoService` | Memory | Encrypt/decrypt orchestration |
| `sessionInitService` | `CryptoSessionInitializationService` | Memory | Session init handshake |
| `registrationBundleService` | `RegistrationBundleService` | Memory | Bundle generation |
| `sessionRestoreService` | `SessionRestoreService` | Memory | Lazy session loading |
| `bundleSignatureService` | `BundleSignatureService` | Memory | Ed25519 bundle signing |
| `preKeyTracker` | `PreKeyTrackingStore` | Memory + Keychain | Detects app reinstalls |
| `wasRestoredFromKeychain` | `Bool` | Memory | Flag: core was persisted |
| `gcTimer` | `Timer?` | Memory | Periodic archive cleanup |

### Data Storage Locations

```
KEYCHAIN:
  ├─ Private keys JSON (identity_secret, signing_secret, signed_prekey_secret)
  ├─ Session JSONs per userId (exported from Rust core)
  ├─ Session archives per userId (max 3, retention 7 days)
  └─ Prekey tracking data

MEMORY (Swift):
  ├─ Active sessionIds[userId→sessionId] mapping
  ├─ Suite IDs per session
  ├─ Archive cache (avoids repeated Keychain reads)
  └─ Timer for GC

RUST CORE (Arc<ClassicCryptoCore>):
  └─ All active session state (double-ratchet, message numbers, etc.)

USER_DEFAULTS:
  ├─ Suite ID per userId (construct.session.suite.{userId})
  └─ PQXDH downgrade flags (construct.pqxdh.downgraded.{userId})
```

### Key Methods & What They Do

#### Core FFI Calls Already Made

| Method | Rust FFI Call | What It Does |
|--------|---------------|--------------|
| `exportSigningSecretKey()` | `core.exportPrivateKeysJson()` | Extracts signing secret for device registration |
| `generateRegistrationBundle()` | `core.exportRegistrationBundleJson()` + `core.exportPrivateKeysJson()` | Creates fresh bundle for device signup |
| `initializeSession()` | `core.initSession(contactId, bundle)` | Initiator X3DH handshake (delegates to CryptoSessionInitializationService) |
| `initReceivingSession()` | `core.initReceivingSession(contactId, bundle, msg)` | Responder X3DH + decrypt msg0 (delegates) |
| `encryptMessage()` | (via MessageCryptoService) `core.encryptMessage()` | Double-ratchet encrypt |
| `decryptMessage()` | (via MessageCryptoService) `core.decryptMessage()` | Double-ratchet decrypt with fallback archives |
| `archiveSession()` | `core.exportSessionJson()` + `core.removeSession()` | Save session state before disposal |
| `restoreLatestArchive()` | `core.importSessionJson()` | Restore archived session state to Rust core |
| `persistCoreState()` | `core.exportPrivateKeysJson()` | Save private key state after SPK rotation |
| `reloadCoreFromKeychain()` | (via CryptoCoreProvider) Reloads from Keychain | Rollback failed SPK rotation |

#### Pure Swift Orchestration (No Crypto)

| Method | Logic | Can Move to Rust? |
|--------|-------|-------------------|
| `trackPreKeyId()` | Detects prekey changes (reinstall detection) + archives session if changed | ✅ **YES** - State machine logic |
| `startGarbageCollectionTimer()` | Timer for cleanup | ✅ **MAYBE** - But Rust can't access timers; keep in Swift |
| `cleanupArchivedSessions()` | Calls archiveManager to remove expired archives | ✅ **YES** - Policy logic |
| `restoreRecentSessions()` | Lazy loads sessions from Keychain for recent chats | ⚠️ **PARTIAL** - Pagination logic stays Swift, core import goes to Rust |
| `restoreSession()` | Deserializes session JSON into Rust core | ✅ **YES** - Just FFI wrapper |
| `hasSession()` / `getSessionId()` | Memory cache queries | ✅ **YES** - State lookup |
| `getAllSessionUserIds()` | Returns active session keys | ✅ **YES** - State query |
| `archiveSession()` | Export→archive→remove from core/Keychain | ✅ **YES** - State transition |
| `restoreLatestArchive()` | Restores most recent archive (tie-breaking) | ✅ **YES** - State transition |
| `deleteSession()` (deprecated) | Remove session from core/Keychain | ✅ **YES** - State removal |
| `tryDecryptWithArchivedSessions()` | Loop through archives, try decrypt, restore on success | ✅ **YES** - Decision logic + state recovery |
| `setLocalUserId()` | Passes userId to Rust core for AAD binding | ✅ **YES** - Config method |
| `deleteAllCryptoKeys()` | Nullify core + delete all Keychain data | ✅ **YES** - Wipe operation |

### Archive Fallback Logic (Lines 665-725)

**Current Implementation**: 
- On decryption failure, try importing archived sessions one-by-one into Rust core
- Snapshot active session before trying archives (to restore if all fail)
- Use reversed enumeration (newest first)
- On success: restore as active, remove from archives, return plaintext
- On all-fail: restore snapshot, throw error

**Can This Move to Rust?**
✅ **ABSOLUTELY YES** — This is pure state machine logic that belongs in OrchestratorCore:
- Iterate archived sessions (stored as JSON strings)
- Call `tryDecryptWithArchived(messageId, ephemeralKey, etc.)`
- Return success + which archive was used, OR failure
- Swift just calls the decision and handles the result

---

## 2. SESSIONARCHIVEMANAGER.SWIFT (113 lines)

### Instance Variables

| Property | Type | Storage | Purpose |
|----------|------|---------|---------|
| `keychain` | `KeychainManager` | Dependency injection | Keychain access |
| `maxArchivedSessions` | `Int` | Memory | Max archives per user (default: 3) |
| `retentionDays` | `Int` | Memory | Max age for archives (default: 7) |
| `archives` | `[String: [SessionArchive]]` | Memory cache | userId → list of archives |

### All Methods

| Method | Lines | What It Does | Rust FFI | Storage |
|--------|-------|-------------|----------|---------|
| `loadArchives(for userId)` | 27-36 | Load from memory cache or Keychain | None | Memory + Keychain |
| `storeArchive(_,for userId)` | 38-46 | Append archive, keep max 3, save | None | Memory + Keychain |
| `restoreArchiveToCurrent()` | 48-55 | Remove archive at index, save list | None | Memory + Keychain |
| `clearArchives(for userId)` | 57-61 | Delete all archives for user | None | Memory + Keychain |
| `cleanupExpiredArchives()` | 63-80 | Remove archives older than 7 days | None | Memory + Keychain |
| `keychainKey(for userId)` | 82-84 | Construct Keychain key | None | N/A |
| `saveToKeychain()` | 86-98 | JSONEncode + save to Keychain | None | Keychain |
| `loadFromKeychain()` | 100-111 | Load + JSONDecode from Keychain | None | Keychain |

### Can This Move to Rust?

⚠️ **PARTIAL**:
- **Archive state management** (list, expiration, max count logic): ✅ **YES** → Move to OrchestratorCore
- **Keychain I/O**: ❌ **MUST STAY IN SWIFT** — Keychain is platform-specific
- **JSON serialization**: ✅ **Could go to Rust** but manageable in Swift for small payloads

**Recommended Approach**:
```rust
// In OrchestratorCore
pub fn archive_session(contact_id: &str, reason: String) -> String  // exports JSON
pub fn restore_archived_session(contact_id: &str, index: usize) -> Result<()>
pub fn cleanup_expired_archives() -> usize  // returns count deleted
pub fn list_archived_sessions(contact_id: &str) -> Vec<ArchiveMetadata>
```

**Swift still handles**:
- Loading archives from Keychain
- Saving OrchestratorCore's returned JSON to Keychain
- Calling Rust cleanup periodically

---

## 3. CRYPTOSESSIONINITIALIZATIONSERVICE.SWIFT (363 lines)

### No Instance Variables
This is a stateless service (only takes `core`, `sessionStore`, callbacks).

### Key Methods

| Method | Lines | Rust FFI Calls | What It Does |
|--------|-------|----------------|-------------|
| `initializeSession()` (INITIATOR) | 12-141 | `core.initSession()` | Base64 decode bundle → call Rust for X3DH → if Kyber available: `PQCKeyManager.encapsulateAndDefer()` |
| `initReceivingSession()` (RESPONDER) | 143-362 | `core.initReceivingSession()` | Decode bundle + msg0 → call Rust → decrypt msg0 → if KEM ciphertext present: `PQCKeyManager.decapsulateAndStrengthen()` |

### Data Flow

```
INITIATOR:
  Input: recipientBundle(base64 fields) + optional Kyber keys
  ├─ Base64 decode all fields (identityPublic, signedPrekeyPublic, signature, verifyingKey)
  ├─ Build JSON dict with [UInt8] arrays
  ├─ Call Rust: core.initSession(contactId, bundleBytes) → sessionId
  ├─ Save sessionId to memory (SessionStore)
  ├─ If Kyber OTPK available: encapsulate → return kemCiphertext + kyberOtpkId
  └─ Return (kemCiphertext, kyberOtpkId) for msg0

RESPONDER:
  Input: recipientBundle + firstMessage(ChatMessage with content, ephemeralKey, msgNum)
  ├─ Base64 decode bundle fields
  ├─ Unpad firstMessage.content (but don't base64-decode it—keep as string for serde)
  ├─ Build JSON dict for bundle + message
  ├─ Call Rust: core.initReceivingSession(contactId, bundleBytes, messageBytes)
  │  → Returns: {sessionId, decryptedMessage}
  ├─ Save sessionId to memory (SessionStore)
  ├─ If KEM ciphertext in firstMessage:
  │  └─ Decapsulate (using Kyber OTPK secret if kyberOtpkId > 0, else SPK)
  │  └─ Strengthen session with PQ material
  └─ Return plaintext of msg0
```

### Can This Move to Rust?

✅ **MOSTLY YES**, with caveats:

**Currently Rust-side**:
- X3DH handshake (`initSession`, `initReceivingSession`)
- Message decryption

**Currently Swift-side but can move**:
- Base64 decoding → Rust can accept raw bytes or base64 strings
- JSON serialization → Rust can build the JSON

**CANNOT move**:
- Keychain lookups for Kyber OTPK secret (`PQCKeyManager.kyberOtpkSecret()`)
- PQC encapsulation/decapsulation (`PQCKeyManager.encapsulateAndDefer()`, etc.)

**Recommended Approach**:
```rust
// OrchestratorCore handles session init completely
pub fn init_session(
    contact_id: &str,
    bundle_json: &str,
    kyber_spk_public: Option<&[u8]>,
    kyber_otpk_public: Option<(&[u8], u32)>
) -> Result<InitSessionResult> {
    // Returns: {sessionId, kemCiphertext, kyberOtpkId}
}

pub fn init_receiving_session(
    contact_id: &str,
    bundle_json: &str,
    message_json: &str,
    kyber_secrets: KyberSecretProvider  // Callback to Swift for secrets
) -> Result<InitReceivingResult> {
    // Returns: {sessionId, decryptedMessage}
}
```

Swift provides a callback for Kyber operations (since Keychain access is platform-specific).

---

## SUMMARY: WHAT MOVES TO RUST

### ✅ DEFINITE MOVES

1. **Session State Machine** (CryptoManager lines 444-725)
   - `hasSession()`, `getSessionId()`, `getAllSessionUserIds()` 
   - `archiveSession()`, `restoreLatestArchive()`
   - Session lifecycle tracking

2. **Archive Fallback Logic** (CryptoManager.tryDecryptWithArchivedSessions())
   - Loop through archives, import, try decrypt
   - Snapshot/restore logic
   - **Belongs in OrchestratorCore**

3. **Session Initialization Ceremony** (CryptoSessionInitializationService)
   - Refactor to accept raw bytes/JSON from Swift
   - Rust does base64 decode, bundle validation, X3DH
   - Return sessionId + optional KEM ciphertext

4. **Archive Management Lifecycle** (SessionArchiveManager)
   - Archive expiration policy
   - Max count enforcement
   - **Keep Keychain I/O in Swift**

### ⚠️ CONDITIONAL MOVES

1. **Tracking/Detection** (trackPreKeyId)
   - State machine: ✅ Move to Rust
   - Timer + callback: ❌ Keep in Swift

2. **Restoration Workflows** (cleanupArchivedSessions, restoreRecentSessions)
   - Policy logic: ✅ Move
   - Pagination + Keychain I/O: ❌ Keep in Swift

### ❌ MUST STAY IN SWIFT

1. **Keychain Operations** (all crypto key persistence)
   - Platform dependency
   - Swift Security framework only

2. **Garbage Collection Timer** (startGarbageCollectionTimer)
   - Platform async/timers
   - Rust can't schedule

3. **PQC Ceremony** (PQCKeyManager calls)
   - Kyber secret lookup from Keychain
   - ML-KEM implicit rejection handling (platform-specific)

4. **UserDefaults** (suite ID, PQXDH flags)
   - Platform storage

---

## RUST ORCHESTRATORCORE API DESIGN

```rust
pub struct OrchestratorCore {
    // Private fields
    active_sessions: HashMap<String, SessionState>,
    archived_sessions: HashMap<String, Vec<ArchivedSession>>,
    classic_core: ClassicCryptoCore,
    // ... other fields
}

impl OrchestratorCore {
    // Session queries
    pub fn has_session(&self, contact_id: &str) -> bool
    pub fn get_session_id(&self, contact_id: &str) -> Option<String>
    pub fn all_session_contact_ids(&self) -> Vec<String>
    
    // Session initialization
    pub fn init_session(
        &mut self,
        contact_id: &str,
        bundle_json: &str,
        kyber_spk: Option<&[u8]>,
    ) -> Result<(String, Option<Vec<u8>>)>  // (sessionId, kemCiphertext)
    
    pub fn init_receiving_session(
        &mut self,
        contact_id: &str,
        bundle_json: &str,
        message_json: &str,
    ) -> Result<(String, String)>  // (sessionId, plaintext)
    
    // Encryption/Decryption
    pub fn encrypt_message(
        &mut self,
        contact_id: &str,
        plaintext: &str,
    ) -> Result<EncryptedMessage>
    
    pub fn decrypt_message(
        &mut self,
        contact_id: &str,
        message_json: &str,
    ) -> Result<String>  // plaintext
    
    // Archive/Recovery
    pub fn archive_session(
        &mut self,
        contact_id: &str,
        reason: &str,
    ) -> Result<()>
    
    pub fn try_decrypt_with_archived(
        &mut self,
        contact_id: &str,
        message_json: &str,
    ) -> Result<(String, usize)>  // (plaintext, archive_index)
    
    pub fn restore_archived_session(
        &mut self,
        contact_id: &str,
        archive_index: usize,
    ) -> Result<()>
    
    pub fn cleanup_expired_archives(&mut self) -> usize
    
    // State persistence
    pub fn export_session_json(&self, contact_id: &str) -> Result<String>
    pub fn import_session_json(
        &mut self,
        contact_id: &str,
        session_json: &str,
    ) -> Result<()>
    
    // PQC coordination
    pub fn apply_kem_ciphertext(
        &mut self,
        contact_id: &str,
        kem_ciphertext: &[u8],
    ) -> Result<()>
}
```

---

## SWIFT-SIDE AFTER MIGRATION

```swift
class CryptoManager {
    private var orchestrator: OrchestratorCore?  // Rust
    private let keychain: KeychainManager        // Platform storage
    private let pqcManager: PQCKeyManager        // Kyber secrets
    
    // Thin wrappers that delegate to orchestrator
    func initializeSession(...) throws {
        // 1. Decode bundle to JSON
        // 2. Call orchestrator.init_session()
        // 3. If kemCiphertext returned: pqcManager.encapsulateAndDefer()
        // 4. Export session from orchestrator, save to Keychain
    }
    
    func decryptMessage(...) throws -> String {
        // 1. Call orchestrator.decrypt_message()
        // 2. On failure: call orchestrator.try_decrypt_with_archived()
        // 3. On archive success: persist state to Keychain
    }
    
    func archiveSession(...) {
        // 1. Call orchestrator.archive_session()
        // 2. Export archived session JSON, save to Keychain
    }
}
```

