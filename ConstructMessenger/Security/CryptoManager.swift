//
//  CryptoManager.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//  Updated for UniFFI clean API on 26.12.2025
//
//  This class is now a Swift wrapper around the UniFFI-generated Rust `construct-core` library.
//  Rust handles ALL crypto operations internally - Swift just passes wire format.
//

import Foundation
import CoreData
import os.log

/// Singleton wrapper around the Rust `construct-core` FFI.
///
/// **Threading requirement**: All methods that touch `orchestratorCore` or `_bootstrapCore`
/// must be called from the same thread (in practice `@MainActor`). The only known exception
/// is `BackgroundFetchManager`, which dispatches crypto calls via `MainActor.run`.
/// Do NOT call crypto methods from arbitrary background threads or Tasks.
class CryptoManager {
    static let shared = CryptoManager()

    // Two-phase init: _bootstrapCore holds ClassicCryptoCore before userId is known;
    // orchestratorCore is created in setLocalUserId() once userId is available.
    // Internal access for InviteGenerator (needs to export keys)
    internal var orchestratorCore: OrchestratorCore?

    /// True once OrchestratorCore has been successfully created from Keychain keys.
    /// On macOS the engine owns the OrchestratorCore; always reports initialized so auth
    /// flows don't fall into the "keys missing" branch.
    var isInitialized: Bool {
        #if os(macOS)
        return true
        #else
        return orchestratorCore != nil
        #endif
    }
    private var _bootstrapCore: ClassicCryptoCore?
    private var _cachedUserId: String?

    /// Returns the local user identity for Double Ratchet AEAD associated data.
    ///
    /// MUST be the server-assigned UUID so both parties bind the session to the same
    /// identifier: the INITIATOR stores `local_user_id = serverUUID` and the RESPONDER
    /// stores `contact_id = serverUUID` for the same party — making the swapped AD
    /// (`local_user_id || contact_id` on encrypt ↔ `contact_id || local_user_id` on
    /// decrypt) deterministically symmetric.  Using the device-hash here (32 hex chars)
    /// while `contact_id` is a 36-char UUID causes permanent AEAD failure.
    private var cryptoLocalUserId: String {
        _cachedUserId ?? ""
    }
    private let coreProvider = CryptoCoreProvider()
    
    // Serializes all access to orchestratorCore and _bootstrapCore so that
    // callers on different threads (e.g. BackgroundFetchManager, MessageRouter)
    // don't race on Rust FFI state. Recursive to allow safe nested calls
    // (e.g. encrypt/decrypt → saveSessionToKeychain).
    let coreLock = NSRecursiveLock()

    /// Set to true when the orchestrator is initialized fresh (no CFE state found).
    /// In this case next_otpk_id resets to 1,000,000, so any OTPKs the server holds
    /// from a previous session have different key material for overlapping IDs.
    /// The next OTPK upload MUST use replaceExisting=true to wipe stale server keys.
    private(set) var needsFullOtpkReplacement = false

    func clearNeedsFullOtpkReplacement() {
        needsFullOtpkReplacement = false
    }

    /// Guards against calling restoreRecentSessions() more than once per process lifetime.
    private var hasRestoredSessions = false

    // MARK: - Session Archive
    let archiveManager = SessionArchiveManager()
    private let messageCrypto = MessageCryptoService()
    private let sessionInitService = CryptoSessionInitializationService()
    let sessionRestoreService = SessionRestoreService()
    
    // MARK: - Prekey ID Tracking
    private let preKeyTracker = PreKeyTrackingStore()

    /// True when core was loaded from saved Keychain keys (not freshly generated).
    /// On startup the server's OTPK set may not match the restored core's state,
    /// so the startup OTPK check must replace all server keys instead of just replenishing.
    private(set) var wasRestoredFromKeychain: Bool = false
    
    // MARK: - Garbage Collection
    
    /// Timer for periodic archive cleanup (24 hours)
    private var gcTimer: Timer?
    
    /// GC interval (24 hours)
    private let gcIntervalSeconds: TimeInterval = 24 * 60 * 60

    private init() {
        let (loadedCore, restoredFromKeychain) = coreProvider.loadCore()
        self._bootstrapCore = loadedCore
        self.wasRestoredFromKeychain = restoredFromKeychain

        // Defer GC and timer to avoid accessing Core Data before stores are loaded.
        // Session restore is intentionally NOT done here — orchestratorCore is not yet
        // available. It will be triggered inside setLocalUserId() once the core is ready.
        DispatchQueue.main.async { [weak self] in
            self?.cleanupArchivedSessions()
            self?.startGarbageCollectionTimer()
        }
    }
    
    // MARK: - Garbage Collection
    
    /// Start periodic garbage collection timer (runs every 24 hours)
    private func startGarbageCollectionTimer() {
        gcTimer?.invalidate()  // Cancel existing timer if any
        
        gcTimer = Timer.scheduledTimer(withTimeInterval: gcIntervalSeconds, repeats: true) { [weak self] _ in
            Log.debug("Running periodic archive garbage collection", category: "CryptoManager")
            self?.cleanupArchivedSessions()
        }
        
        // Add to RunLoop to ensure it fires even when app is in background
        if let timer = gcTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        Log.debug("Started archive GC timer (interval: 24h)", category: "CryptoManager")
    }
    
    deinit {
        // Stop GC timer on dealloc
        gcTimer?.invalidate()
        // UniFFI manages memory automatically via Arc<T>
        // No manual cleanup needed!
    }
    
    // MARK: - Device Registration

    /// Export signing secret key from current core (for device-signed flows).
    func exportSigningSecretKey() throws -> [UInt8] {
        let keyBytes: Data
        if let oc = orchestratorCore {
            keyBytes = try oc.getSigningKeyBytes()
        } else if let bc = _bootstrapCore {
            keyBytes = try bc.getSigningKeyBytes()
        } else {
            throw CryptoManagerError.coreNotInitialized
        }
        guard !keyBytes.isEmpty else {
            throw CryptoError.InvalidKeyData(message: "getSigningKeyBytes returned empty")
        }
        return [UInt8](keyBytes)
    }
    
    /// Expose local public key fields for server consistency checks.
    func localBundlePublicKeys() throws -> (identityPublic: Data, signedPrekeyPublic: Data) {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        let fields = try core.getRegistrationBundleFields()
        return (Data(fields.identityPublic), Data(fields.signedPrekeyPublic))
    }

    /// Generate a complete registration bundle for device-based authentication
    /// Returns: (deviceId, registrationBundle fields, signing key bytes, identity key bytes)
    func generateRegistrationBundle() throws -> (deviceId: String, bundle: RegistrationBundleFields, signingKey: Data, identityKey: Data) {
        Log.info("Generating registration bundle...", category: "CryptoManager")

        // Always generate fresh keys for registration — never reuse an existing core
        // (an old core would carry a signature computed with the previous prologue/suite_id)
        let activeCore = try createCryptoCore()
        self._bootstrapCore = activeCore

        // Persist in CFE binary format immediately (no JSON fallback)
        let cfeData = try Data(activeCore.exportPrivateKeys())
        let saved = KeychainManager.shared.savePrivateKeys(cfeData)
        if saved {
            Log.info("Saved registration private keys (CFE) to Keychain", category: "CryptoManager")
        } else {
            Log.error("Failed to save registration private keys to Keychain", category: "CryptoManager")
        }

        // Typed bundle — bytes are bytes, no base64, no JSON
        let bundle = try activeCore.getRegistrationBundleFields()
        let identityHexPreview = bundle.identityPublic.prefix(8).map { String(format: "%02x", $0) }.joined()
        Log.debug("Registration bundle: identity=\(identityHexPreview)… suiteId=\(bundle.suiteId)", category: "CryptoManager")

        // Key bytes — no JSON parsing
        let signingKeyData = try activeCore.getSigningKeyBytes()
        let identityKeyData = try activeCore.getIdentityKeyBytes()
        guard !signingKeyData.isEmpty, !identityKeyData.isEmpty else {
            throw CryptoError.InvalidKeyData(message: "getSigningKeyBytes or getIdentityKeyBytes returned empty")
        }

        // Derive device_id from identity public key bytes directly.
        let deviceId = deriveDeviceId(identityPublicKey: bundle.identityPublic)

        Log.info("Generated registration bundle: device_id=\(deviceId)", category: "CryptoManager")
        return (deviceId, bundle, signingKeyData, identityKeyData)
    }

    // MARK: - Prekey ID Tracking
    
    /// Track a prekey ID for a user and detect reinstall
    /// Returns true if prekey changed (potential reinstall detected)
    public func trackPreKeyId(_ preKeyId: String, for userId: String) -> Bool {
        let result = preKeyTracker.track(preKeyId: preKeyId, for: userId)
        switch result {
        case .firstSeen:
            Log.debug("Tracking prekey for \(userId): \(preKeyId.prefix(8))...", category: "CryptoManager")
            return false
        case .unchanged:
            return false
        case .changed(let previous):
            let previousPrefix = previous.isEmpty ? "unknown" : String(previous.prefix(8))
            Log.info("Prekey changed for \(userId): \(previousPrefix)... -> \(preKeyId.prefix(8))...", category: "CryptoManager")
            Log.info("This indicates app reinstall or key rotation", category: "CryptoManager")
            
            // Archive existing session (if any)
            if hasSession(for: userId) {
                archiveSession(for: userId, reason: .preKeyChanged)
                Log.info("Session archived due to prekey change", category: "CryptoManager")
            }
            
            return true
        }
    }

    // MARK: - Session Persistence

    /// Save session to Keychain after state change.
    /// Includes verify-after-write: reads back the blob to confirm integrity.
    func saveSessionToKeychain(for userId: String) {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return }
        do {
            let sessionData = Data(try core.exportSession(contactId: userId))
            var saved = false
            for attempt in 1...3 {
                saved = KeychainManager.shared.saveSessionData(sessionData, for: userId)
                guard saved else {
                    Log.error("Keychain write failed (attempt \(attempt)/3): \(userId)", category: "CryptoManager")
                    continue
                }
                // Verify round-trip: read back and compare byte count.
                if let readBack = KeychainManager.shared.loadSessionData(for: userId),
                   readBack.count == sessionData.count {
                    Log.debug("Session saved+verified (\(sessionData.count)B): \(userId)", category: "CryptoManager")
                    return
                }
                Log.error("Session verify-after-write mismatch (attempt \(attempt)/3): \(userId)", category: "CryptoManager")
            }
            if !saved {
                Log.error("Failed to save session to Keychain after 3 attempts: \(userId)", category: "CryptoManager")
            }
        } catch {
            Log.error("Session export failed: \(error)", category: "CryptoManager")
        }
    }

    /// Persist the current Rust core private key state to Keychain.
    ///
    /// Call after in-core mutations (e.g., SPK rotation via `rotateSignedPrekey()`)
    /// so the updated state survives app restarts.
    /// Persist the current Rust core state (private keys incl. SPK) to Keychain.
    ///
    /// - Returns: `true` if the Keychain write succeeded; `false` on any failure.
    ///   Callers that MUST NOT proceed with a stale Keychain (e.g. SPK rotation)
    ///   should check the return value and roll back if `false`.
    @discardableResult
    func persistCoreState() -> Bool {
        guard let core = orchestratorCore else {
            Log.error("persistCoreState: core not initialized", category: "CryptoManager")
            return false
        }
        do {
            let data = Data(try core.exportPrivateKeys())
            let saved = KeychainManager.shared.savePrivateKeys(data)
            if saved {
                Log.info("Persisted Rust core state (CFE) to Keychain", category: "CryptoManager")
            } else {
                Log.error("Failed to persist Rust core state — Keychain save returned false", category: "CryptoManager")
            }
            return saved
        } catch {
            Log.error("persistCoreState: export failed: \(error)", category: "CryptoManager")
            return false
        }
    }

    /// Reload the Rust core from Keychain, discarding any in-memory mutations.
    ///
    /// Call after a failed SPK rotation to roll back the in-memory state change
    /// made by `rotateSignedPrekey()`, ensuring the core stays in sync with the
    /// Keychain (and thus with what the server has).
    func reloadCoreFromKeychain() {
        guard _cachedUserId != nil else {
            Log.error("reloadCoreFromKeychain: no cached userId — cannot recreate OrchestratorCore", category: "CryptoManager")
            return
        }
        guard let keysData = KeychainManager.shared.loadPrivateKeysData() else {
            Log.error("reloadCoreFromKeychain: failed to reload — Keychain state unavailable", category: "CryptoManager")
            return
        }
        let cryptoId = cryptoLocalUserId
        do {
            let newCore = try createOrchestratorCoreFromKeys(keysData: [UInt8](keysData), myUserId: cryptoId)
            if let otpksData = KeychainManager.shared.loadOtpksData() {
                do {
                    try newCore.importOneTimePrekeys(data: [UInt8](otpksData))
                    Log.debug("Imported OTPKs on core reload (\(newCore.oneTimePrekeyCount()) keys)", category: "CryptoManager")
                } catch {
                    Log.error("Failed to import OTPKs on core reload: \(error)", category: "CryptoManager")
                }
            }
            PQCKeyManager.loadCFESnapshot(into: newCore)
            loadOrchestratorStateCFE(into: newCore)
            orchestratorCore = newCore
            Log.info("Rust core reloaded from Keychain (CFE)", category: "CryptoManager")
        } catch {
            Log.error("reloadCoreFromKeychain: OrchestratorCore init failed: \(error)", category: "CryptoManager")
        }
    }

    // MARK: - Orchestrator State CFE Persistence

    private static let orchestratorStateCFEKey = "construct.orchestrator_state"

    /// Save the full orchestrator coordination state (ACK cache, healing queue,
    /// init locks, archive index) to Keychain as a CFE blob.
    /// Call after any significant state change in the orchestrator.
    func saveOrchestratorStateCFE() {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return }
        do {
            let blob = try core.exportOrchestratorState()
            // AfterFirstUnlock (not WhenUnlocked): the Double Ratchet state advances during
            // background push-driven decrypt while the device is locked. A WhenUnlocked save
            // fails there → the advanced ratchet is never persisted → desync on next launch.
            let ok = KeychainManager.shared.saveData(
                Data(blob),
                forKey: Self.orchestratorStateCFEKey,
                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
            if ok {
                Log.debug("Orchestrator state saved (CFE, \(blob.count)B)", category: "CryptoManager")
            } else {
                Log.error("Orchestrator state CFE save failed (Keychain write error)", category: "CryptoManager")
            }
        } catch {
            Log.error("Orchestrator state CFE export failed: \(error)", category: "CryptoManager")
        }
    }

    /// Restore the orchestrator coordination state into `core` from Keychain.
    /// Called during `reloadCoreFromKeychain` and `setLocalUserId`.
    private func loadOrchestratorStateCFE(into core: OrchestratorCore) {
        guard let data = KeychainManager.shared.loadData(forKey: Self.orchestratorStateCFEKey) else {
            Log.debug("No orchestrator state CFE found in Keychain (first launch or cleared)", category: "CryptoManager")
            // Fresh orchestrator: next_otpk_id resets to 1,000,000. Any OTPKs on the server
            // from a previous partial upload share those IDs but have different key material.
            // Force a replace-all on the next OTPK upload to eliminate the stale server keys.
            needsFullOtpkReplacement = true
            return
        }
        do {
            try core.importOrchestratorState(data: [UInt8](data))
            Log.info("Orchestrator state restored (CFE, \(data.count)B)", category: "CryptoManager")
        } catch {
            Log.error("Orchestrator state CFE import failed: \(error) — starting fresh", category: "CryptoManager")
        }
    }

    /// Delete the persisted orchestrator state (e.g., on full account reset).
    func clearOrchestratorStateCFE() {
        KeychainManager.shared.deleteData(forKey: Self.orchestratorStateCFEKey)
        Log.debug("Orchestrator state CFE cleared", category: "CryptoManager")
    }

    /// Mark an ACK as processed inside the Rust orchestrator cache (serialized).
    func markAckProcessedInOrchestrator(messageId: String) {
        coreLock.lock()
        defer { coreLock.unlock() }
        orchestratorCore?.ackMarkProcessed(messageId: messageId)
    }

    // MARK: - Orchestrator Event Bridge

    /// Single, serialized entry point for all `OrchestratorCore.handleEvent` calls.
    ///
    /// Why: The Rust orchestrator mutates DR state (ratchets, ACK cache, healing queue).
    /// Calling it concurrently (even from different Swift Tasks) can corrupt session state
    /// and manifest as "session out of sync" without obvious triggers.
    @discardableResult
    func handleOrchestratorEvent(
        _ event: CfeIncomingEvent,
        tag: String? = nil
    ) throws -> [CfeAction] {
        if !Thread.isMainThread {
            Log.fault(
                "Orchestrator event off main thread: \(orchestratorEventSummary(event))" + (tag.map { " tag=\($0)" } ?? ""),
                category: "CryptoOrchestrator"
            )
        }

        coreLock.lock()
        defer { coreLock.unlock() }

        guard let core = orchestratorCore else {
            throw CryptoManagerError.coreNotInitialized
        }

        let actions = try core.handleEvent(event: event)
        logOrchestratorEvent(event, actions: actions, tag: tag)
        return actions
    }

    // MARK: - Locked Core Operation Wrappers

    // All methods below acquire coreLock before touching orchestratorCore.
    // External callers MUST use these instead of accessing orchestratorCore directly.

    /// Sign binary data using the device Ed25519 identity key.
    func signBundleData(_ bundleData: [UInt8]) throws -> Data {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        let sigBytes = try core.signBundleData(bundleDataJson: bundleData)
        return Data(sigBytes)
    }

    // MARK: - Hybrid PQ Identity Signatures (Ed25519 + ML-DSA-65)
    //
    // These wrap the stateless `hybrid*` free functions from construct-core. They do
    // NOT touch orchestratorCore, so no coreLock is needed. The 2016-byte hybrid
    // private key lives in Keychain (WhenUnlockedThisDeviceOnly) and is wiped by
    // deleteAllCryptoKeys()/deleteAllKeys() (account deletion, duress, local reset).
    //
    // Client and server share the SAME implementation (RustCrypto ml-dsa, seed-based),
    // so every format is byte-identical and signatures cross-verify:
    //   private key 2016 = [ed25519_seed (32)] [mldsa65_seed (32)] [mldsa65_pk (1952)]
    //   public key  1984 = [ed25519_pk (32)] [mldsa65_pk (1952)]
    //   signature   3373 = [ed25519_sig (64)] [mldsa65_sig (3309)]

    /// Returns the device hybrid identity public key (1984 bytes), generating and
    /// persisting a fresh hybrid keypair on first use.
    @discardableResult
    func ensureHybridIdentityPublicKey() throws -> Data {
        if let stored = KeychainManager.shared.loadHybridSigPrivateKey() {
            return Data(try hybridPublicKeyFromPrivate(privateKey: [UInt8](stored)))
        }
        let pair = try hybridSignatureKeygen()
        guard KeychainManager.shared.saveHybridSigPrivateKey(Data(pair.privateKey)) else {
            throw CryptoManagerError.invalidKeyData
        }
        Log.info("Generated hybrid PQ identity signing keypair (Ed25519 + ML-DSA-65)", category: "CryptoManager")
        return Data(pair.publicKey)
    }

    /// The device hybrid identity public key if a keypair already exists, else nil
    /// (does not generate one).
    func hybridIdentityPublicKey() -> Data? {
        guard let stored = KeychainManager.shared.loadHybridSigPrivateKey() else { return nil }
        return (try? hybridPublicKeyFromPrivate(privateKey: [UInt8](stored))).map { Data($0) }
    }

    /// Signs a message with the device hybrid identity key, generating the keypair on
    /// first use. Returns a 3373-byte hybrid signature.
    func signHybrid(_ message: [UInt8]) throws -> Data {
        let priv: [UInt8]
        if let stored = KeychainManager.shared.loadHybridSigPrivateKey() {
            priv = [UInt8](stored)
        } else {
            let pair = try hybridSignatureKeygen()
            guard KeychainManager.shared.saveHybridSigPrivateKey(Data(pair.privateKey)) else {
                throw CryptoManagerError.invalidKeyData
            }
            Log.info("Generated hybrid PQ identity signing keypair (Ed25519 + ML-DSA-65)", category: "CryptoManager")
            priv = pair.privateKey
        }
        return Data(try hybridSign(privateKey: priv, message: message))
    }

    /// Verifies a hybrid signature against a peer's hybrid public key. Both the
    /// Ed25519 and ML-DSA-65 components must validate. Stateless.
    func verifyHybrid(publicKey: [UInt8], message: [UInt8], signature: [UInt8]) throws -> Bool {
        return try hybridVerify(publicKey: publicKey, message: message, signature: signature)
    }

    /// Apply a Kyber KEM shared secret to the named DR session.
    func applyPqContribution(contactId: String, kemSharedSecret: [UInt8]) throws {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        try core.applyPqContribution(contactId: contactId, kemSharedSecret: kemSharedSecret)
    }

    /// Register a Kyber KEM shared secret for deferred application and persist CFE snapshot.
    @discardableResult
    func registerPqDeferred(contactId: String, otpkId: UInt32, sharedSecret: [UInt8]) -> Bool {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return false }
        core.registerPqDeferred(contactId: contactId, otpkId: otpkId, sharedSecret: sharedSecret)
        PQCKeyManager.saveCFESnapshot(to: core)
        return true
    }

    /// Export the Kyber session state as a CFE blob.
    func exportKyberSessionState() -> [UInt8]? {
        coreLock.lock()
        defer { coreLock.unlock() }
        return try? orchestratorCore?.exportKyberSessionState()
    }

    /// Import Kyber session state from a CFE blob.
    func importKyberSessionState(_ data: [UInt8]) throws {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        try core.importKyberSessionState(data: data)
    }

    /// Persist the current Kyber CFE snapshot to Keychain.
    func savePQCSnapshot() {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { return }
        PQCKeyManager.saveCFESnapshot(to: core)
    }

    /// Rotate the signed pre-key and return the new public material.
    func rotateSignedPrekey() throws -> RotatedSpkBundle {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.rotateSignedPrekey()
    }

    /// Generate a batch of fresh X25519 OTPKs.
    func generateOneTimePrekeys(count: UInt32) throws -> [OtpkPair] {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.generateOneTimePrekeys(count: count)
    }

    /// Export all OTPK private keys as a CFE blob.
    func exportOneTimePrekeys() throws -> [UInt8] {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.exportOneTimePrekeys()
    }

    /// Number of OTPKs currently held in the Rust core.
    func oneTimePrekeyCount() -> UInt32 {
        coreLock.lock()
        defer { coreLock.unlock() }
        return orchestratorCore?.oneTimePrekeyCount() ?? 0
    }

    /// Export a session's wire bytes (for session init completed notification).
    func exportSession(contactId: String) throws -> [UInt8] {
        coreLock.lock()
        defer { coreLock.unlock() }
        guard let core = orchestratorCore else { throw CryptoManagerError.coreNotInitialized }
        return try core.exportSession(contactId: contactId)
    }

    // MARK: - Key Management

    /// Delete all saved cryptographic keys and sessions (e.g., on account deletion)
    /// After calling this, the app will generate fresh keys on next registration
    func deleteAllCryptoKeys() {
        Log.info("Deleting all cryptographic data from Keychain...", category: "CryptoManager")

        // Nullify in-memory cores so next registration generates a fresh keypair
        self.orchestratorCore = nil
        self._bootstrapCore = nil

        // Delete private keys JSON (identity, signed prekey, signing key)
        KeychainManager.shared.deletePrivateKeys()

        // Delete all individual keys and ALL sessions
        KeychainManager.shared.deleteAllKeys()

        Log.info("All cryptographic keys and sessions deleted from Keychain", category: "CryptoManager")
        Log.info("On next app launch, fresh cryptographic keys will be generated", category: "CryptoManager")
    }

    // MARK: - Registration

        // MARK: - Session Management

    /// Initializes a secure session with a recipient using the Rust core.
    func initializeSession(for userId: String, recipientBundle: (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data, suiteId: String), oneTimePreKeyPublic: Data? = nil, oneTimePreKeyId: UInt32? = nil, kyberPreKeyPublic: Data? = nil, kyberOneTimePreKeyPublic: Data? = nil, kyberOneTimePreKeyId: UInt32? = nil, spkUploadedAt: UInt64 = 0, spkRotationEpoch: UInt32 = 0, kyberSpkUploadedAt: UInt64 = 0, kyberSpkRotationEpoch: UInt32 = 0) throws {
        do {
            try sessionInitService.initializeSession(
                for: userId,
                recipientBundle: recipientBundle,
                oneTimePreKeyPublic: oneTimePreKeyPublic,
                oneTimePreKeyId: oneTimePreKeyId,
                kyberPreKeyPublic: kyberPreKeyPublic,
                kyberOneTimePreKeyPublic: kyberOneTimePreKeyPublic,
                kyberOneTimePreKeyId: kyberOneTimePreKeyId,
                spkUploadedAt: spkUploadedAt,
                spkRotationEpoch: spkRotationEpoch,
                kyberSpkUploadedAt: kyberSpkUploadedAt,
                kyberSpkRotationEpoch: kyberSpkRotationEpoch,
                core: orchestratorCore,
                archiveSession: { [weak self] userId, reason in
                    Log.info("Existing session found for \(userId) - archiving before reinitialization to prevent desync", category: "CryptoManager")
                    self?.archiveSession(for: userId, reason: reason)
                },
                saveSession: { [weak self] userId in
                    self?.saveSessionToKeychain(for: userId)
                }
            )
            Log.info("Session initialized for user: \(userId)", category: "CryptoManager")
        } catch let sessionError as SessionError {
            throw sessionError
        } catch CryptoManagerError.invalidKeyData {
            Log.error("Failed to decode base64-encoded keys from bundle", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        } catch CryptoManagerError.sessionInitializationFailed {
            Log.error("Failed to initialize session", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        } catch {
            Log.error("Unexpected error initializing session: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    /// Set the local user ID in the crypto core so AAD correctly binds sender identity.
    /// `userId` is the server-assigned account UUID; this same UUID is stored as
    /// `local_user_id` in the Rust Double Ratchet session and must match the `contact_id`
    /// the remote party uses for the local device — see `cryptoLocalUserId`.
    func setLocalUserId(_ userId: String) {
        _cachedUserId = userId
        #if !os(macOS)
        let cryptoId = cryptoLocalUserId

        if let existing = orchestratorCore {
            existing.setLocalUserId(userId: cryptoId)
            migrateSessionsIfNeeded(core: existing)
            Log.debug("CryptoManager: updated local user ID to \(cryptoId.prefix(8))… (server UUID)", category: "CryptoManager")
            return
        }

        // Build OrchestratorCore from Keychain or bootstrap core keys.
        let keysData: [UInt8]?
        if let d = KeychainManager.shared.loadPrivateKeysData() {
            keysData = [UInt8](d)
        } else if let bootstrapData = try? _bootstrapCore?.exportPrivateKeys() {
            keysData = bootstrapData
        } else {
            Log.error("setLocalUserId: no keys available to create OrchestratorCore", category: "CryptoManager")
            return
        }

        guard let keys = keysData else { return }

        do {
            let newCore = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: cryptoId)
            // Import OTPKs if available
            if let otpksData = KeychainManager.shared.loadOtpksData() {
                do {
                    try newCore.importOneTimePrekeys(data: [UInt8](otpksData))
                    Log.debug("Imported OTPKs into OrchestratorCore (\(newCore.oneTimePrekeyCount()) keys)", category: "CryptoManager")
                } catch {
                    Log.error("Failed to import OTPKs into OrchestratorCore: \(error)", category: "CryptoManager")
                }
            } else {
                Log.info("No OTPKs found in Keychain — key_manager will have empty OTPK store", category: "CryptoManager")
            }
            // Restore Kyber deferred contribution state from CFE snapshot.
            PQCKeyManager.loadCFESnapshot(into: newCore)
            // Restore ACK cache, healing queue, and init locks.
            loadOrchestratorStateCFE(into: newCore)
            migrateSessionsIfNeeded(core: newCore)
            orchestratorCore = newCore
            _bootstrapCore = nil
            Log.debug("CryptoManager: OrchestratorCore created (userId=\(cryptoId.prefix(8))…)", category: "CryptoManager")
            // Session restore was skipped in init() because orchestratorCore was not yet
            // available. Now that the core is ready, restore sessions on the next run loop
            // tick (Core Data is guaranteed to be loaded by this point).
            if !hasRestoredSessions {
                hasRestoredSessions = true
                DispatchQueue.main.async { [weak self] in
                    self?.restoreRecentSessions(limit: 10)
                }
            }
        } catch {
            Log.error("setLocalUserId: OrchestratorCore init failed: \(error)", category: "CryptoManager")
        }
        #endif
    }

    /// One-time migration: sessions saved before the AD fix (build < 350) stored
    /// `local_user_id` as a 32-char device-hash instead of the server UUID.  Those
    /// sessions can never decrypt correctly.  On first launch with the fixed code we
    /// wipe all persisted sessions so fresh X3DH handshakes establish correct AD.
    private func migrateSessionsIfNeeded(core: OrchestratorCore) {
        let migrationKey = "construct.adMigration.serverUUID.v1.done"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        let contactIds = core.getAllSessionContactIds()
        for contactId in contactIds {
            _ = core.removeSession(contactId: contactId)
            KeychainManager.shared.deleteSession(for: contactId)
        }
        if !contactIds.isEmpty {
            Log.info("AD migration: cleared \(contactIds.count) stale session(s) with wrong local_user_id — fresh handshakes will use server UUID", category: "CryptoManager")
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    func hasSession(for userId: String) -> Bool {
        return orchestratorCore?.hasSession(contactId: userId) ?? false
    }

    /// Return a read-only health snapshot for the session with `userId`.
    /// Returns `nil` if no session exists or the core is not initialized.
    func getSessionHealth(for userId: String) -> SessionHealthReport? {
        return orchestratorCore?.getSessionHealth(contactId: userId)
    }

    /// Get all user IDs with active sessions
    /// Used for sending END_SESSION to all contacts on logout
    func getAllSessionUserIds() -> [String] {
        return orchestratorCore?.getAllSessionContactIds() ?? []
    }

    /// Initialize a receiving session (for responder/Bob) using sender's bundle + first message.
    /// Returns the raw decrypted bytes of the first message (KNST frame, protobuf, or UTF-8 control string).
    /// Callers must decode via `ChunkedMessageReassembler.process(data:)` — do NOT convert to String here.
    func initReceivingSession(
        for userId: String,
        recipientBundle: (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data, suiteId: String),
        firstMessage: ChatMessage,
        spkUploadedAt: UInt64 = 0,
        spkRotationEpoch: UInt32 = 0,
        kyberSpkUploadedAt: UInt64 = 0,
        kyberSpkRotationEpoch: UInt32 = 0
    ) throws -> Data {
        do {
            let plaintext = try sessionInitService.initReceivingSession(
                for: userId,
                recipientBundle: recipientBundle,
                firstMessage: firstMessage,
                spkUploadedAt: spkUploadedAt,
                spkRotationEpoch: spkRotationEpoch,
                kyberSpkUploadedAt: kyberSpkUploadedAt,
                kyberSpkRotationEpoch: kyberSpkRotationEpoch,
                core: orchestratorCore,
                archiveSession: { [weak self] userId, reason in
                    Log.info("Existing session found for \(userId) - archiving before receiving session init to prevent desync", category: "CryptoManager")
                    self?.archiveSession(for: userId, reason: reason)
                },
                saveSession: { [weak self] userId in
                    self?.saveSessionToKeychain(for: userId)
                }
            )
            Log.info("Receiving session initialized for user: \(userId), decrypted message length: \(plaintext.count)", category: "CryptoManager")
            return plaintext
        } catch CryptoManagerError.invalidKeyData {
            Log.error("Failed to decode base64-encoded keys from bundle", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        } catch CryptoManagerError.sessionInitializationFailed {
            Log.error("Failed to initialize receiving session", category: "CryptoManager")
            logLocalKeyDiagnostics()
            throw CryptoManagerError.sessionInitializationFailed
        } catch {
            Log.error("Unexpected error initializing receiving session: \(error)", category: "CryptoManager")
            logLocalKeyDiagnostics()
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    // MARK: - Key Diagnostics

    /// Log local public key prefixes for post-mortem analysis when session init fails.
    /// Allows comparing with what the server served to the INITIATOR.
    private func logLocalKeyDiagnostics() {
        guard let core = orchestratorCore else { return }
        do {
            let fields = try core.getRegistrationBundleFields()
            func hexPrefix(_ bytes: [UInt8]) -> String {
                bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
            }
            let ik = hexPrefix(fields.identityPublic)
            let spk = hexPrefix(fields.signedPrekeyPublic)
            let vk = hexPrefix(fields.verifyingKey)
            Log.error("LOCAL KEY DIAGNOSTICS — identity=\(ik)… spk=\(spk)… vk=\(vk)…", category: "CryptoManager")
        } catch {
            Log.error("LOCAL KEY DIAGNOSTICS: export failed: \(error)", category: "CryptoManager")
        }
    }

    // MARK: - Encryption / Decryption

    /// Result of message encryption with separate fields per server ChatMessage spec
    typealias EncryptedMessageComponents = MessageCryptoService.EncryptedMessageComponents

    /// Encrypts a plaintext message using the session for a specific user
    /// Returns separate components per server ChatMessage format
    func encryptMessage(_ message: String, for userId: String) throws -> EncryptedMessageComponents {
        // coreLock serializes Rust FFI calls so that a background task and the main
        // actor cannot advance the DR ratchet concurrently (would corrupt chain state).
        coreLock.lock()
        defer { coreLock.unlock() }
        let components = try messageCrypto.encryptMessage(
            message,
            for: userId,
            core: orchestratorCore,
            restoreSession: { [weak self] userId in
                Log.info("Session not in memory, attempting restore: \(userId)", category: "CryptoManager")
                return self?.restoreSession(for: userId) ?? false
            },
            saveSession: { [weak self] userId in
                self?.saveSessionToKeychain(for: userId)
            },
            archiveSession: { [weak self] userId, reason in
                Log.debug("Archiving session for \(userId) to allow reinitialization", category: "CryptoManager")
                self?.archiveSession(for: userId, reason: reason)
            }
        )

        Log.debug("ENCRYPT: msgNum=\(components.messageNumber), otpkId=\(components.oneTimePreKeyId), ephemKey=\(components.ephemeralPublicKey.prefix(8).map { String(format: "%02x", $0) }.joined()), content=\(components.content.count) bytes", category: "CryptoManager")

        return components
    }

    /// Decrypt a ChatMessage directly using clean API
    /// Uses clean API - Rust handles all MessagePack internally
    /// Now with Session Archive fallback support
    func decryptMessage(_ message: ChatMessage) throws -> MessageDecryptResult {
        try decryptMessage(message, contactIdOverride: nil)
    }

    func decryptMessage(_ message: ChatMessage, contactIdOverride: String?) throws -> MessageDecryptResult {
        let logContactId = contactIdOverride ?? message.from
        Log.debug("Decrypting message \(message.id.prefix(8))... contactId=\(logContactId.prefix(16))...", category: "CryptoManager")
        Log.debug("messageNumber: \(message.messageNumber)", category: "CryptoManager")
        Log.debug("ephemeralPublicKey: \(message.ephemeralPublicKey.count) bytes", category: "CryptoManager")
        Log.debug("content length: \(message.content.count) bytes", category: "CryptoManager")

        // Last-resort duplicate guard: if the foreground stream already processed this
        // message (preemptACK was called in routeIncomingMessage), the DR state has
        // already advanced past it.  Attempting to decrypt would fail and incorrectly
        // archive a healthy session — throw duplicateMessage instead so the caller can
        // skip silently without triggering session recovery.
        if PersistentACKStore.shared.isProcessedInMemory(message.id) {
            Log.info("CryptoManager: \(message.id.prefix(8))… already in ACK cache — skipping duplicate decrypt", category: "CryptoManager")
            throw CryptoManagerError.duplicateMessage
        }

        // coreLock serializes decrypt alongside encrypt — concurrent decrypts on the same
        // session advance the DR receive chain non-deterministically.
        coreLock.lock()
        defer { coreLock.unlock() }
        let decryptResult: MessageCryptoService.DecryptResult
        do {
            decryptResult = try messageCrypto.decryptMessage(
                message,
                contactIdOverride: contactIdOverride,
                core: orchestratorCore,
                restoreSession: { [weak self] userId in
                    Log.info("Session not in memory, attempting restore: \(userId)", category: "CryptoManager")
                    return self?.restoreSession(for: userId) ?? false
                },
                saveSession: { [weak self] userId in
                    self?.saveSessionToKeychain(for: userId)
                },
                archiveSession: { [weak self] userId, reason in
                    // ERROR-level so this appears in exported logs even at INFO filter.
                    // The message ID is included so the log can be correlated with the
                    // BackgroundFetch / MessageStream event that triggered the archive.
                    Log.error("CryptoManager: archiving session for \(userId.prefix(8))… reason=\(reason) msgId=\(message.id.prefix(8))… msgNum=\(message.messageNumber)", category: "CryptoManager")
                    self?.archiveSession(for: userId, reason: reason)
                },
                tryDecryptWithArchived: { [weak self] message in
                    guard let self = self else {
                        throw CryptoManagerError.decryptionFailed
                    }
                    let plaintext = try self.tryDecryptWithArchivedSessions(message: message)
                    Log.info("Successfully decrypted with archived session!", category: "CryptoManager")
                    return plaintext
                }
            )
        } catch {
            Log.error("Rust core decryptMessage failed for \(message.id.prefix(8))… msgNum=\(message.messageNumber): \(error)", category: "CryptoManager")
            throw error
        }

        Log.info("Message decrypted successfully (messageNumber: \(message.messageNumber), plaintext: \(decryptResult.plaintext.count) bytes)", category: "CryptoManager")
        return MessageDecryptResult(plaintext: decryptResult.plaintext, storageKey: decryptResult.storageKey)
    }

    /// Background-safe DR decrypt — no `archiveSession` callback on failure.
    ///
    /// Called exclusively from `BackgroundFetchManager` (private BG queue, hopped to main
    /// via `DispatchQueue.main.sync`). Unlike the foreground `decryptMessage`, this method
    /// never archives the session on failure — it simply throws `.decryptionFailedNoArchive`
    /// so the caller can skip the message.  The foreground stream will handle recovery
    /// (END_SESSION, re-init, healing) when the app becomes active.
    ///
    /// Precondition: the caller must restore the session with `restoreSession(for:)` before
    /// calling this method.  If no session exists, throws `.sessionNotFound`.
    func decryptMessageForBackground(_ message: ChatMessage) throws -> MessageDecryptResult {
        // Fast duplicate guard — no I/O, protects DR state.
        if PersistentACKStore.shared.isProcessedInMemory(message.id) {
            throw CryptoManagerError.duplicateMessage
        }

        coreLock.lock()
        defer { coreLock.unlock() }

        guard let core = orchestratorCore else {
            throw CryptoManagerError.coreNotInitialized
        }

        guard core.hasSession(contactId: message.from) else {
            throw CryptoManagerError.sessionNotFound
        }

        let contentForDecrypt = MessagePadding.unpadCiphertext(message.content)

        do {
            let result = try core.decryptMessage(
                contactId: message.from,
                ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                messageNumber: message.messageNumber,
                content: [UInt8](contentForDecrypt)
            )
            saveSessionToKeychain(for: message.from)
            Log.info("BG decrypt OK \(message.id.prefix(8))… msgNum=\(message.messageNumber) (\(result.plaintext.count) bytes)", category: "CryptoManager")
            return MessageDecryptResult(plaintext: Data(result.plaintext), storageKey: Data(result.storageKey))
        } catch {
            // Do NOT call archiveSession here. The session may still be healthy —
            // failure here is likely a race (duplicate), a skipped key, or a stale
            // message from before session re-init. The foreground stream owns recovery.
            Log.info("BG decrypt failed \(message.id.prefix(8))… msgNum=\(message.messageNumber): \(error) — session preserved", category: "CryptoManager")
            throw CryptoManagerError.decryptionFailedNoArchive(reason: error.localizedDescription)
        }
    }

    /// Batch offline decrypt — single Rust mutex acquisition for the entire batch.
    ///
    /// Maps each `ChatMessage` to an `OfflineBatchMessage`, calls the Rust
    /// `decrypt_offline_batch` method, then returns typed `OfflineBatchDecryptResult`
    /// values.  Per-message failures do NOT abort the batch and do NOT archive any session.
    ///
    /// The caller is responsible for:
    ///   - session restore (call `restoreSession(for:)` per contactId before calling this)
    ///   - storing returned `storageKey` values in `MessageKeyStore`
    ///   - calling `PersistentACKStore.preemptACK` for successfully decrypted messages
    func decryptOfflineBatch(_ messages: [ChatMessage]) -> [OfflineBatchDecryptResult] {
        // Fast pre-filter: drop anything already in the in-memory ACK cache.
        let filtered = messages.filter { !PersistentACKStore.shared.isProcessedInMemory($0.id) }
        guard !filtered.isEmpty else { return [] }

        coreLock.lock()
        defer { coreLock.unlock() }

        guard let core = orchestratorCore else {
            return filtered.map { OfflineBatchDecryptResult(message: $0, plaintext: nil,
                error: CryptoManagerError.coreNotInitialized, storageKey: Data()) }
        }

        let inputs: [OfflineBatchMessage] = filtered.map { msg in
            OfflineBatchMessage(
                id: msg.id,
                contactId: msg.from,
                ephemeralPublicKey: [UInt8](msg.ephemeralPublicKey),
                messageNumber: msg.messageNumber,
                content: [UInt8](MessagePadding.unpadCiphertext(msg.content))
            )
        }

        let results = core.decryptOfflineBatch(messages: inputs)

        // Zip back to ChatMessage for the caller.
        return zip(filtered, results).map { (chatMsg, batchResult) in
            if let plaintext = batchResult.plaintext {
                saveSessionToKeychain(for: chatMsg.from)
                Log.info("Batch BG decrypt OK \(chatMsg.id.prefix(8))… msgNum=\(chatMsg.messageNumber) (\(plaintext.count) bytes)", category: "CryptoManager")
                return OfflineBatchDecryptResult(
                    message: chatMsg,
                    plaintext: Data(plaintext),
                    error: nil,
                    storageKey: Data(batchResult.storageKey)
                )
            } else {
                let reason = batchResult.error ?? "unknown"
                Log.info("Batch BG decrypt failed \(chatMsg.id.prefix(8))… msgNum=\(chatMsg.messageNumber): \(reason) — session preserved", category: "CryptoManager")
                return OfflineBatchDecryptResult(
                    message: chatMsg,
                    plaintext: nil,
                    error: CryptoManagerError.decryptionFailedNoArchive(reason: reason),
                    storageKey: Data()
                )
            }
        }
    }

    /// Decrypt raw Double Ratchet components — used for call signaling fields, not ChatMessage.
    /// Returns UTF-8 string (call signals are always valid UTF-8).
    /// Handles session restore from Keychain if needed. Does not try archived sessions.
    func decryptRawComponents(
        contactId: String,
        ephemeralPublicKey: Data,
        messageNumber: UInt32,
        content: Data
    ) throws -> String {
        coreLock.lock()
        defer { coreLock.unlock() }

        guard let core = orchestratorCore else {
            throw CryptoManagerError.coreNotInitialized
        }

        if !core.hasSession(contactId: contactId) {
            if !restoreSession(for: contactId) {
                throw CryptoManagerError.sessionNotFound
            }
        }

        guard core.hasSession(contactId: contactId) else {
            throw CryptoManagerError.sessionNotFound
        }

        let contentForDecrypt = MessagePadding.unpadCiphertext(content)
        let result = try core.decryptMessage(
            contactId: contactId,
            ephemeralPublicKey: [UInt8](ephemeralPublicKey),
            messageNumber: messageNumber,
            content: [UInt8](contentForDecrypt)
        )
        saveSessionToKeychain(for: contactId)
        return String(data: Data(result.plaintext), encoding: .utf8) ?? ""
    }

}
