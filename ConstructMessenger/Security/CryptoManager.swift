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
    // ⚠️ Internal access for InviteGenerator (needs to export keys)
    internal var orchestratorCore: OrchestratorCore?
    private var _bootstrapCore: ClassicCryptoCore?
    private var _cachedKeysJson: String?
    private var _cachedUserId: String?
    private let coreProvider = CryptoCoreProvider()
    
    // Serializes all access to orchestratorCore and _bootstrapCore so that
    // callers on different threads (e.g. BackgroundFetchManager, MessageRouter)
    // don't race on Rust FFI state.
    private let coreLock = NSLock()

    // MARK: - Session Archive
    private let archiveManager = SessionArchiveManager()
    private let messageCrypto = MessageCryptoService()
    private let sessionInitService = CryptoSessionInitializationService()
    private let registrationBundleService = RegistrationBundleService()
    private let sessionRestoreService = SessionRestoreService()
    private let bundleSignatureService = BundleSignatureService()
    
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

        // ✅ Restore recent sessions (pagination - first 10 chats)
        // ⚠️ Defer to avoid accessing Core Data before stores are loaded
        // This will be called later when Core Data is ready
        DispatchQueue.main.async { [weak self] in
            self?.restoreRecentSessions(limit: 10)
            // 🆕 Run garbage collection after restoring sessions
            self?.cleanupArchivedSessions()
            // 🆕 Prekey tracker loads from storage on init
            // 🆕 Start periodic GC timer (24 hours)
            self?.startGarbageCollectionTimer()
        }
    }
    
    // MARK: - Garbage Collection
    
    /// Start periodic garbage collection timer (runs every 24 hours)
    private func startGarbageCollectionTimer() {
        gcTimer?.invalidate()  // Cancel existing timer if any
        
        gcTimer = Timer.scheduledTimer(withTimeInterval: gcIntervalSeconds, repeats: true) { [weak self] _ in
            Log.debug("🗑️ Running periodic archive garbage collection", category: "CryptoManager")
            self?.cleanupArchivedSessions()
        }
        
        // Add to RunLoop to ensure it fires even when app is in background
        if let timer = gcTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        Log.debug("⏰ Started archive GC timer (interval: 24h)", category: "CryptoManager")
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
        let keysJSON: String
        if let oc = orchestratorCore {
            keysJSON = try oc.exportPrivateKeysJson()
        } else if let bc = _bootstrapCore {
            keysJSON = try bc.exportPrivateKeysJson()
        } else {
            throw CryptoManagerError.coreNotInitialized
        }
        guard let data = keysJSON.data(using: .utf8),
              let keys = try? JSONDecoder().decode(PrivateKeysJSON.self, from: data),
              let signingSecretData = Data(base64Encoded: keys.signingSecret) else {
            throw CryptoError.InvalidKeyData(message: "Failed to decode signing secret key")
        }

        return [UInt8](signingSecretData)
    }
    
    /// Generate a complete registration bundle for device-based authentication
    /// Returns: (deviceId, registrationBundle JSON, signing key bytes, identity key bytes)
    func generateRegistrationBundle() throws -> (deviceId: String, bundleJson: String, signingKey: Data, identityKey: Data) {
        Log.info("🔑 Generating registration bundle...", category: "CryptoManager")
        
        // Always generate fresh keys for registration — never reuse an existing core
        // (an old core would carry a signature computed with the previous prologue/suite_id)
        let activeCore = try createCryptoCore()
        self._bootstrapCore = activeCore
        
        // Export registration bundle (contains all public keys)
        let bundleJson = try activeCore.exportRegistrationBundleJson()
        Log.debug("📦 Registration bundle: \(bundleJson.prefix(200))...", category: "CryptoManager")
        
        // Export private keys to extract what we need (JSON for intermediate parsing)
        let privateKeysJson = try activeCore.exportPrivateKeysJson()
        self._cachedKeysJson = privateKeysJson
        Log.debug("🔐 Private keys JSON: \(privateKeysJson.prefix(200))...", category: "CryptoManager")

        // Persist in CFE binary format
        let saved: Bool
        if let cfeData = try? Data(activeCore.exportPrivateKeys()) {
            saved = KeychainManager.shared.savePrivateKeys(cfeData)
        } else {
            saved = KeychainManager.shared.savePrivateKeysJson(privateKeysJson)
        }
        if saved {
            Log.info("✅ Saved registration private keys (CFE) to Keychain", category: "CryptoManager")
        } else {
            Log.error("⚠️ Failed to save registration private keys to Keychain", category: "CryptoManager")
        }
        
        // Parse private keys JSON to get signing and identity keys
        guard let keysData = privateKeysJson.data(using: .utf8) else {
            Log.error("❌ Failed to convert privateKeysJson to UTF-8 data", category: "CryptoManager")
            throw CryptoError.InvalidKeyData(message: "Failed to convert private keys JSON to UTF-8")
        }
        
        guard let keysDict = try? JSONSerialization.jsonObject(with: keysData) as? [String: Any] else {
            Log.error("❌ Failed to parse JSON: \(privateKeysJson)", category: "CryptoManager")
            throw CryptoError.InvalidKeyData(message: "Failed to deserialize private keys JSON")
        }
        
        Log.debug("📋 Keys dict keys: \(keysDict.keys.joined(separator: ", "))", category: "CryptoManager")
        
        // ✅ Use snake_case (Rust convention)
        guard let signingSecret = keysDict["signing_secret"] as? String else {
            Log.error("❌ Missing 'signing_secret' in keys: \(keysDict.keys)", category: "CryptoManager")
            throw CryptoError.InvalidKeyData(message: "Missing 'signing_secret' in private keys JSON")
        }
        
        guard let identitySecret = keysDict["identity_secret"] as? String else {
            Log.error("❌ Missing 'identity_secret' in keys: \(keysDict.keys)", category: "CryptoManager")
            throw CryptoError.InvalidKeyData(message: "Missing 'identity_secret' in private keys JSON")
        }
        
        // Convert base64 strings to Data (Rust returns base64, not hex)
        guard let signingKeyData = Data(base64Encoded: signingSecret) else {
            Log.error("❌ Failed to decode signingSecret base64: \(signingSecret.prefix(20))...", category: "CryptoManager")
            throw CryptoError.InvalidKeyData(message: "Failed to decode signing key base64 string")
        }
        
        guard let identityKeyData = Data(base64Encoded: identitySecret) else {
            Log.error("❌ Failed to decode identitySecret base64: \(identitySecret.prefix(20))...", category: "CryptoManager")
            throw CryptoError.InvalidKeyData(message: "Failed to decode identity key base64 string")
        }
        
        // Derive device_id from identity public key
        // Parse bundle JSON to get identity public key (base64 from Rust)
        guard let bundleData = bundleJson.data(using: .utf8),
              let bundleDict = try? JSONSerialization.jsonObject(with: bundleData) as? [String: Any],
              let identityPublic = bundleDict["identity_public"] as? String,
              let identityPublicBytes = Data(base64Encoded: identityPublic) else {
            Log.error("❌ Failed to parse registration bundle JSON", category: "CryptoManager")
            throw CryptoError.InvalidKeyData(message: "Failed to parse registration bundle JSON")
        }
        
        // Compute device_id using Rust function
        let deviceId = deriveDeviceId(identityPublicKey: [UInt8](identityPublicBytes))
        
        Log.info("✅ Generated registration bundle: device_id=\(deviceId)", category: "CryptoManager")
        
        return (deviceId, bundleJson, signingKeyData, identityKeyData)
    }

    // MARK: - Private Keys JSON Structure

    /// Matches Rust PrivateKeysJson structure (snake_case)
    private struct PrivateKeysJSON: Codable {
        let identitySecret: String
        let signingSecret: String
        let signedPrekeySecret: String
        let prekeySignature: String
        let suiteId: String

        enum CodingKeys: String, CodingKey {
            case identitySecret = "identity_secret"
            case signingSecret = "signing_secret"
            case signedPrekeySecret = "signed_prekey_secret"
            case prekeySignature = "prekey_signature"
            case suiteId = "suite_id"
        }
    }
    
    // MARK: - Prekey ID Tracking
    
    /// Track a prekey ID for a user and detect reinstall
    /// Returns true if prekey changed (potential reinstall detected)
    public func trackPreKeyId(_ preKeyId: String, for userId: String) -> Bool {
        let result = preKeyTracker.track(preKeyId: preKeyId, for: userId)
        switch result {
        case .firstSeen:
            Log.debug("📝 Tracking prekey for \(userId): \(preKeyId.prefix(8))...", category: "CryptoManager")
            return false
        case .unchanged:
            return false
        case .changed(let previous):
            let previousPrefix = previous.isEmpty ? "unknown" : String(previous.prefix(8))
            Log.info("⚠️ Prekey changed for \(userId): \(previousPrefix)... -> \(preKeyId.prefix(8))...", category: "CryptoManager")
            Log.info("   This indicates app reinstall or key rotation", category: "CryptoManager")
            
            // Archive existing session (if any)
            if hasSession(for: userId) {
                archiveSession(for: userId, reason: .preKeyChanged)
                Log.info("🗄️ Session archived due to prekey change", category: "CryptoManager")
            }
            
            return true
        }
    }

    // MARK: - Session Persistence

    /// Save session to Keychain after state change
    private func saveSessionToKeychain(for userId: String) {
        guard let core = orchestratorCore else { return }
        do {
            let sessionData = Data(try core.exportSession(contactId: userId))
            let saved = KeychainManager.shared.saveSessionData(sessionData, for: userId)
            if saved {
                Log.debug("💾 Session (CFE) saved to Keychain: \(userId)", category: "CryptoManager")
            } else {
                Log.debug("⚠️ Failed to save session to Keychain: \(userId)", category: "CryptoManager")
            }
        } catch {
            Log.error("❌ Session export failed: \(error)", category: "CryptoManager")
        }
    }

    /// Internal: save session to Keychain (used by deferred PQXDH application).
    func saveSessionToKeychainPublic(for userId: String) {
        saveSessionToKeychain(for: userId)
    }

    /// Persist the current Rust core private key state to Keychain.
    ///
    /// Call after in-core mutations (e.g., SPK rotation via `rotateSignedPrekey()`)
    /// so the updated state survives app restarts.
    func persistCoreState() {
        guard let core = orchestratorCore else {
            Log.error("❌ persistCoreState: core not initialized", category: "CryptoManager")
            return
        }
        do {
            let data = Data(try core.exportPrivateKeys())
            let saved = KeychainManager.shared.savePrivateKeys(data)
            if saved {
                Log.info("✅ Persisted Rust core state (CFE) to Keychain", category: "CryptoManager")
            } else {
                Log.error("❌ Failed to persist Rust core state — Keychain save returned false", category: "CryptoManager")
            }
        } catch {
            Log.error("❌ persistCoreState: export failed: \(error)", category: "CryptoManager")
        }
    }

    /// Reload the Rust core from Keychain, discarding any in-memory mutations.
    ///
    /// Call after a failed SPK rotation to roll back the in-memory state change
    /// made by `rotateSignedPrekey()`, ensuring the core stays in sync with the
    /// Keychain (and thus with what the server has).
    func reloadCoreFromKeychain() {
        guard let userId = _cachedUserId else {
            Log.error("❌ reloadCoreFromKeychain: no cached userId — cannot recreate OrchestratorCore", category: "CryptoManager")
            return
        }
        guard let keysData = KeychainManager.shared.loadPrivateKeysData() else {
            Log.error("❌ reloadCoreFromKeychain: failed to reload — Keychain state unavailable", category: "CryptoManager")
            return
        }
        do {
            let newCore = try createOrchestratorCoreFromKeys(keysData: [UInt8](keysData), myUserId: userId)
            if let otpksData = KeychainManager.shared.loadOtpksData() {
                do {
                    try newCore.importOneTimePrekeys(data: [UInt8](otpksData))
                    Log.debug("✅ Imported OTPKs on core reload (\(newCore.oneTimePrekeyCount()) keys)", category: "CryptoManager")
                } catch {
                    Log.error("❌ Failed to import OTPKs on core reload: \(error)", category: "CryptoManager")
                }
            }
            PQCKeyManager.loadCFESnapshot(into: newCore)
            loadOrchestratorStateCFE(into: newCore)
            orchestratorCore = newCore
            Log.info("🔄 Rust core reloaded from Keychain (CFE)", category: "CryptoManager")
        } catch {
            Log.error("❌ reloadCoreFromKeychain: OrchestratorCore init failed: \(error)", category: "CryptoManager")
        }
    }

    // MARK: - Orchestrator State CFE Persistence

    private static let orchestratorStateCFEKey = "construct.orchestrator_state"

    /// Save the full orchestrator coordination state (ACK cache, healing queue,
    /// init locks, archive index) to Keychain as a CFE blob.
    /// Call after any significant state change in the orchestrator.
    func saveOrchestratorStateCFE() {
        guard let core = orchestratorCore else { return }
        do {
            let blob = try core.exportOrchestratorState()
            let ok = KeychainManager.shared.saveData(Data(blob), forKey: Self.orchestratorStateCFEKey)
            if ok {
                Log.debug("💾 Orchestrator state saved (CFE, \(blob.count)B)", category: "CryptoManager")
            } else {
                Log.error("❌ Orchestrator state CFE save failed (Keychain write error)", category: "CryptoManager")
            }
        } catch {
            Log.error("❌ Orchestrator state CFE export failed: \(error)", category: "CryptoManager")
        }
    }

    /// Restore the orchestrator coordination state into `core` from Keychain.
    /// Called during `reloadCoreFromKeychain` and `setLocalUserId`.
    private func loadOrchestratorStateCFE(into core: OrchestratorCore) {
        guard let data = KeychainManager.shared.loadData(forKey: Self.orchestratorStateCFEKey) else {
            Log.debug("ℹ️ No orchestrator state CFE found in Keychain (first launch or cleared)", category: "CryptoManager")
            return
        }
        do {
            try core.importOrchestratorState(data: [UInt8](data))
            Log.info("📦 Orchestrator state restored (CFE, \(data.count)B)", category: "CryptoManager")
        } catch {
            Log.error("❌ Orchestrator state CFE import failed: \(error) — starting fresh", category: "CryptoManager")
        }
    }

    /// Delete the persisted orchestrator state (e.g., on full account reset).
    func clearOrchestratorStateCFE() {
        KeychainManager.shared.deleteData(forKey: Self.orchestratorStateCFEKey)
        Log.debug("🗑️ Orchestrator state CFE cleared", category: "CryptoManager")
    }

    /// Clear all archived sessions for a user
    func clearArchivedSessions(for userId: String) {
        archiveManager.clearArchives(for: userId)
        Log.info("🗑️ Cleared all archived sessions for \(userId)", category: "CryptoManager")
    }
    
    /// Garbage collection: Remove archived sessions older than retention period
    /// Called on app launch and periodically
    func cleanupArchivedSessions() {
        let totalRemoved = archiveManager.cleanupExpiredArchives()
        if totalRemoved > 0 {
            Log.info("♻️ Garbage collection complete: removed \(totalRemoved) expired session archives", category: "CryptoManager")
        } else {
            Log.debug("✅ Garbage collection: no expired archives found", category: "CryptoManager")
        }
    }

    /// Restore sessions for recent chats (pagination - first 10)
    func restoreRecentSessions(limit: Int = 10) {
        guard orchestratorCore != nil else {
            Log.error("Cannot restore sessions - core not initialized", category: "CryptoManager")
            return
        }

        var restoredCount = 0
        var failedCount = 0

        sessionRestoreService.restoreRecentSessions(limit: limit) { [weak self] contactId in
            guard let self = self else { return false }
            if self.restoreSession(for: contactId) {
                restoredCount += 1
                return true
            } else {
                failedCount += 1
                return false
            }
        }

        Log.info("📦 Session restore: \(restoredCount) restored, \(failedCount) failed", category: "CryptoManager")
    }

    @discardableResult
    func restoreSession(for userId: String) -> Bool {
        guard let core = orchestratorCore else { return false }
        if core.hasSession(contactId: userId) { return true }
        guard let sessionData = KeychainManager.shared.loadSessionData(for: userId) else {
            Log.error("⚠️ No session data in Keychain for \(userId) — session must be re-established", category: "CryptoManager")
            return false
        }
        do {
            _ = try core.importSession(contactId: userId, data: [UInt8](sessionData))
            Log.debug("✅ Restored session (CFE): \(userId)", category: "CryptoManager")
            return true
        } catch {
            _ = KeychainManager.shared.saveSessionData(Data(), for: userId)
            Log.error("❌ Session import FAILED for \(userId) (stale/incompatible format — cleared): \(error)", category: "CryptoManager")
            return false
        }
    }


    /// Get session ID for a user (for Core Data storage)
    func getSessionId(for userId: String) -> String? {
        return (orchestratorCore?.hasSession(contactId: userId) == true) ? userId : nil
    }

    // MARK: - Key Management

    /// Delete all saved cryptographic keys and sessions (e.g., on account deletion)
    /// After calling this, the app will generate fresh keys on next registration
    func deleteAllCryptoKeys() {
        Log.info("🗑️ Deleting all cryptographic data from Keychain...", category: "CryptoManager")

        // Nullify in-memory cores so next registration generates a fresh keypair
        self.orchestratorCore = nil
        self._bootstrapCore = nil

        // Delete private keys JSON (identity, signed prekey, signing key)
        KeychainManager.shared.deletePrivateKeysJson()

        // Delete all individual keys and ALL sessions
        KeychainManager.shared.deleteAllKeys()

        Log.info("✅ All cryptographic keys and sessions deleted from Keychain", category: "CryptoManager")
        Log.info("ℹ️ On next app launch, fresh cryptographic keys will be generated", category: "CryptoManager")
    }

    // MARK: - Registration

    /// Generates a compact RegistrationBundle struct for display / compatibility purposes.
    /// Use `generateRegistrationBundle() throws` (FFI version) for new registrations.
    func generateLegacyRegistrationBundle() -> RegistrationBundle? {
        guard let bundle = registrationBundleService.generateRegistrationBundle(core: orchestratorCore) else {
            Log.error("❌ Failed to generate registration bundle", category: "CryptoManager")
            return nil
        }
        Log.info("✅ Registration bundle generated successfully", category: "CryptoManager")
        return bundle
    }
    
    /// Sign BundleData JSON with Ed25519 signing key
    /// This creates the signature for UploadableKeyBundle.bundleData
    func signBundleData(_ bundleDataJSON: Data) throws -> String {
        do {
            let signatureBase64 = try bundleSignatureService.signBundleData(bundleDataJSON, core: orchestratorCore)
            Log.debug("✅ BundleData signed successfully", category: "CryptoManager")
            return signatureBase64
        } catch {
            Log.error("❌ Failed to sign BundleData: \(error)", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
    }

    // MARK: - Session Management

    /// Initializes a secure session with a recipient using the Rust core.
    @discardableResult
    func initializeSession(for userId: String, recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String, suiteId: String), oneTimePreKeyPublic: Data? = nil, oneTimePreKeyId: UInt32? = nil, kyberPreKeyPublic: Data? = nil, kyberOneTimePreKeyPublic: Data? = nil, kyberOneTimePreKeyId: UInt32? = nil, spkUploadedAt: UInt64 = 0, spkRotationEpoch: UInt32 = 0, kyberSpkUploadedAt: UInt64 = 0, kyberSpkRotationEpoch: UInt32 = 0) throws -> (kemCiphertext: Data?, kyberOtpkId: UInt32) {
        do {
            let result = try sessionInitService.initializeSession(
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
                    Log.info("⚠️ Existing session found for \(userId) - archiving before reinitialization to prevent desync", category: "CryptoManager")
                    self?.archiveSession(for: userId, reason: reason)
                },
                saveSession: { [weak self] userId in
                    self?.saveSessionToKeychain(for: userId)
                }
            )
            Log.info("✅ Session initialized for user: \(userId)", category: "CryptoManager")
            return result
        } catch CryptoManagerError.invalidKeyData {
            Log.error("Failed to decode base64-encoded keys from bundle", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        } catch CryptoManagerError.sessionInitializationFailed {
            Log.error("❌ Failed to initialize session", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        } catch {
            Log.error("❌ Unexpected error initializing session: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    /// Set the local user ID in the crypto core so AAD correctly binds sender identity.
    /// Must be called after login/registration with the server-assigned userId.
    func setLocalUserId(_ userId: String) {
        _cachedUserId = userId

        if let existing = orchestratorCore {
            existing.setLocalUserId(userId: userId)
            Log.debug("🔑 CryptoManager: updated local user ID to \(userId)", category: "CryptoManager")
            return
        }

        // Build OrchestratorCore — prefer CFE binary from Keychain, fallback to cached JSON
        let keysData: [UInt8]?
        if let cached = _cachedKeysJson, let d = cached.data(using: .utf8) {
            keysData = [UInt8](d)
        } else if let d = KeychainManager.shared.loadPrivateKeysData() {
            keysData = [UInt8](d)
        } else if let bootstrapData = try? _bootstrapCore?.exportPrivateKeys() {
            keysData = bootstrapData
        } else {
            Log.error("❌ setLocalUserId: no keys available to create OrchestratorCore", category: "CryptoManager")
            return
        }

        guard let keys = keysData else { return }

        do {
            let newCore = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: userId)
            // Import OTPKs if available
            if let otpksData = KeychainManager.shared.loadOtpksData() {
                do {
                    try newCore.importOneTimePrekeys(data: [UInt8](otpksData))
                    Log.debug("✅ Imported OTPKs into OrchestratorCore (\(newCore.oneTimePrekeyCount()) keys)", category: "CryptoManager")
                } catch {
                    Log.error("❌ Failed to import OTPKs into OrchestratorCore: \(error)", category: "CryptoManager")
                }
            } else {
                Log.info("⚠️ No OTPKs found in Keychain — key_manager will have empty OTPK store", category: "CryptoManager")
            }
            // Restore Kyber deferred contribution state from CFE snapshot.
            PQCKeyManager.loadCFESnapshot(into: newCore)
            // Restore ACK cache, healing queue, and init locks.
            loadOrchestratorStateCFE(into: newCore)
            orchestratorCore = newCore
            _bootstrapCore = nil
            _cachedKeysJson = nil
            Log.debug("🔑 CryptoManager: OrchestratorCore created for user \(userId)", category: "CryptoManager")
        } catch {
            Log.error("❌ setLocalUserId: OrchestratorCore init failed: \(error)", category: "CryptoManager")
        }
    }

    /// Check if a session exists for a user
    func hasSession(for userId: String) -> Bool {
        let exists = orchestratorCore?.hasSession(contactId: userId) ?? false
        Log.debug("🔑 Session check for \(userId): \(exists ? "EXISTS" : "MISSING")", category: "CryptoManager")
        return exists
    }
    
    /// Get all user IDs with active sessions
    /// Used for sending END_SESSION to all contacts on logout
    func getAllSessionUserIds() -> [String] {
        return orchestratorCore?.getAllSessionContactIds() ?? []
    }

    /// Delete a session for a user (called when deleting a chat)
    /// Archive a session instead of deleting it
    /// Allows fallback decryption for out-of-order messages
    func archiveSession(for userId: String, reason: ArchiveReason) {
        guard let core = orchestratorCore else {
            Log.error("❌ Cannot archive session: Core not initialized", category: "CryptoManager")
            return
        }
        
        Log.info("📦 Archiving session for \(userId), reason: \(reason.rawValue)", category: "CryptoManager")
        
        // 1. Export current session to CFE binary format and store archive.
        //    IMPORTANT: only proceed with deletion if export succeeded — otherwise the session
        //    would be permanently lost with no archive to restore from.
        do {
            let sessionData = Data(try core.exportSession(contactId: userId))
            
            let archive = SessionArchive(
                sessionData: sessionData,
                archivedAt: Date(),
                reason: reason
            )
            archiveManager.storeArchive(archive, for: userId)
            let count = archiveManager.loadArchives(for: userId)?.count ?? 0
            Log.info("✅ Session archived (\(count) total for user)", category: "CryptoManager")
        } catch {
            // If the session is already gone from Rust (SessionNotFound) and we already have
            // an archive (e.g. Rust archived it when we received END_SESSION first), treat
            // this as a successful archive-by-other-means and just clean up.
            let existingCount = archiveManager.loadArchives(for: userId)?.count ?? 0
            if existingCount > 0 {
                Log.info("ℹ️ archiveSession: session already archived via Rust for \(userId.prefix(8))… (reason: \(reason.rawValue)), cleaning up", category: "CryptoManager")
                UserDefaults.standard.removeObject(forKey: "construct.session.suite.\(userId)")
                _ = orchestratorCore?.removeSession(contactId: userId)
                KeychainManager.shared.deleteSession(for: userId)
                return
            }
            Log.error("❌ Failed to export session for archiving — session NOT deleted to prevent data loss: \(error)", category: "CryptoManager")
            // Do not proceed with deletion: losing the session without an archive
            // would permanently break communication with this contact.
            return
        }
        
        // 2. Remove from active storage — only reached when archive is safely stored above.
        UserDefaults.standard.removeObject(forKey: "construct.session.suite.\(userId)")
        Log.info("✅ Removed session suite ID from UserDefaults: \(userId)", category: "CryptoManager")
        
        let removed = (orchestratorCore?.removeSession(contactId: userId)) ?? false
        if removed {
            Log.info("✅ Removed session from Rust core: \(userId)", category: "CryptoManager")
        } else {
            Log.info("⚠️ Session not found in Rust core: \(userId)", category: "CryptoManager")
        }
        
        KeychainManager.shared.deleteSession(for: userId)
        Log.info("✅ Removed session from Keychain: \(userId)", category: "CryptoManager")
    }

    /// Accept a pre-archived session produced by Rust's `lifecycle.archive_session`.
    ///
    /// Called when `handleEventJson` returns a `SaveSessionToSecureStore` action
    /// with key `"archive_<contactId>"`.  Rust has already removed the session from
    /// memory, so we must NOT call `exportSessionJson` here — we store the bytes
    /// Rust handed us directly into `SessionArchiveManager`.
    func acceptRustSessionArchive(contactId: String, sessionJsonBytes: [UInt8]) {
        guard !sessionJsonBytes.isEmpty else {
            Log.error("❌ acceptRustSessionArchive: empty bytes for \(contactId.prefix(8))…", category: "CryptoManager")
            return
        }
        // Rust currently sends JSON bytes; store as Data — import_session has a LegacyJson fallback.
        let archive = SessionArchive(sessionData: Data(sessionJsonBytes), archivedAt: Date(), reason: .endSessionReceived)
        archiveManager.storeArchive(archive, for: contactId)
        let count = archiveManager.loadArchives(for: contactId)?.count ?? 0
        Log.info("📦 acceptRustSessionArchive: archived session for \(contactId.prefix(8))… (\(count) total)", category: "CryptoManager")
    }


    /// Used for tie-breaking when we are the INITIATOR in a dual-INITIATOR clash:
    /// after a failed decrypt the INITIATOR session was just moved to archives —
    /// this undoes that and makes it active again so we keep the INITIATOR role.
    @discardableResult
    func restoreLatestArchive(for userId: String) -> Bool {
        guard let core = orchestratorCore,
              let archives = archiveManager.loadArchives(for: userId),
              !archives.isEmpty else { return false }
        let idx = archives.count - 1
        let latest = archives[idx]
        do {
            let suiteIdBefore = UserDefaults.standard.integer(forKey: "construct.session.suite.\(userId)")
            // importSession handles both CFE binary (new archives) and legacy JSON (old archives).
            _ = try core.importSession(contactId: userId, data: [UInt8](latest.sessionData))
            // Extract suite_id from a fresh re-export of the now-live session — always reliable.
            if let freshJson = try? core.exportSessionJson(contactId: userId),
               let suiteId = Self.extractSuiteId(fromSessionJson: freshJson) {
                UserDefaults.standard.set(suiteId, forKey: "construct.session.suite.\(userId)")
                Log.info("🔑 SESSION_STATE[restore_suite_id]: peer=\(userId.prefix(8))… suiteId \(suiteIdBefore) → \(suiteId)", category: "SessionInit")
            } else {
                Log.error("🚨 SESSION_STATE[restore_suite_id_failed]: peer=\(userId.prefix(8))… suiteId_before=\(suiteIdBefore) — exportSessionJson failed after import; remote decrypt will likely fail", category: "CryptoManager")
            }
            saveSessionToKeychain(for: userId)
            archiveManager.restoreArchiveToCurrent(for: userId, index: idx)
            Log.info("♻️ Restored INITIATOR session from archive for \(userId.prefix(8))… (tie-break)", category: "CryptoManager")
            return true
        } catch {
            Log.error("❌ restoreLatestArchive failed for \(userId.prefix(8))…: \(error)", category: "CryptoManager")
            return false
        }
    }

    private static func extractSuiteId(fromSessionJson json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        func search(_ value: Any) -> Int? {
            if let dict = value as? [String: Any] {
                if let suite = dict["suite_id"] as? Int { return suite }
                if let suite = dict["suiteId"] as? Int { return suite }
                for v in dict.values {
                    if let found = search(v) { return found }
                }
            } else if let arr = value as? [Any] {
                for v in arr {
                    if let found = search(v) { return found }
                }
            }
            return nil
        }

        return search(root)
    }

    /// Delete a session (legacy - use archiveSession instead)
    @available(*, deprecated, message: "Use archiveSession() instead for better error recovery")
    func deleteSession(for userId: String) {
        // Remove suite ID from UserDefaults
        UserDefaults.standard.removeObject(forKey: "construct.session.suite.\(userId)")
        Log.info("✅ Removed session suite ID from UserDefaults: \(userId)", category: "CryptoManager")

        // Remove from the Rust core
        if let core = orchestratorCore {
            if core.removeSession(contactId: userId) {
                Log.info("✅ Removed session from Rust core: \(userId)", category: "CryptoManager")
            } else {
                Log.debug("No session found in Rust core for user \(userId)", category: "CryptoManager")
            }
        }

        // ✅ Remove from Keychain
        KeychainManager.shared.deleteSession(for: userId)
        Log.info("✅ Removed session from Keychain: \(userId)", category: "CryptoManager")
    }

    /// Initialize a receiving session (for responder/Bob) using sender's bundle + first message
    /// This is called when Bob receives the first message from Alice
    /// Returns the decrypted plaintext of the first message
    func initReceivingSession(for userId: String, recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String, suiteId: String), firstMessage: ChatMessage) throws -> String {
        do {
            let plaintext = try sessionInitService.initReceivingSession(
                for: userId,
                recipientBundle: recipientBundle,
                firstMessage: firstMessage,
                core: orchestratorCore,
                archiveSession: { [weak self] userId, reason in
                    Log.info("⚠️ Existing session found for \(userId) - archiving before receiving session init to prevent desync", category: "CryptoManager")
                    self?.archiveSession(for: userId, reason: reason)
                },
                saveSession: { [weak self] userId in
                    self?.saveSessionToKeychain(for: userId)
                }
            )
            Log.info("✅ Receiving session initialized for user: \(userId), decrypted message length: \(plaintext.count)", category: "CryptoManager")
            return plaintext
        } catch CryptoManagerError.invalidKeyData {
            Log.error("Failed to decode base64-encoded keys from bundle", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        } catch CryptoManagerError.sessionInitializationFailed {
            Log.error("❌ Failed to initialize receiving session", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        } catch {
            Log.error("❌ Unexpected error initializing receiving session: \(error)", category: "CryptoManager")
            throw CryptoManagerError.sessionInitializationFailed
        }
    }

    // MARK: - Encryption / Decryption

    /// Result of message encryption with separate fields per server ChatMessage spec
    typealias EncryptedMessageComponents = MessageCryptoService.EncryptedMessageComponents

    /// Encrypts a plaintext message using the session for a specific user
    /// Returns separate components per server ChatMessage format
    func encryptMessage(_ message: String, for userId: String) throws -> EncryptedMessageComponents {
        let components = try messageCrypto.encryptMessage(
            message,
            for: userId,
            core: orchestratorCore,
            restoreSession: { [weak self] userId in
                Log.info("🔄 Session not in memory, attempting restore: \(userId)", category: "CryptoManager")
                return self?.restoreSession(for: userId) ?? false
            },
            saveSession: { [weak self] userId in
                self?.saveSessionToKeychain(for: userId)
            },
            archiveSession: { [weak self] userId, reason in
                Log.debug("🔄 Archiving session for \(userId) to allow reinitialization", category: "CryptoManager")
                self?.archiveSession(for: userId, reason: reason)
            }
        )

        Log.debug("✅ ENCRYPT: msgNum=\(components.messageNumber), otpkId=\(components.oneTimePreKeyId), ephemKey=\(components.ephemeralPublicKey.prefix(8).map { String(format: "%02x", $0) }.joined()), content=\(components.content.prefix(20))...", category: "CryptoManager")

        return components
    }

    /// Decrypt a ChatMessage directly using clean API
    /// Uses clean API - Rust handles all MessagePack internally
    /// Now with Session Archive fallback support
    func decryptMessage(_ message: ChatMessage) throws -> String {
        try decryptMessage(message, contactIdOverride: nil)
    }

    func decryptMessage(_ message: ChatMessage, contactIdOverride: String?) throws -> String {
        let logContactId = contactIdOverride ?? message.from
        Log.debug("🔓 Decrypting message \(message.id.prefix(8))... contactId=\(logContactId.prefix(16))...", category: "CryptoManager")
        Log.debug("   messageNumber: \(message.messageNumber)", category: "CryptoManager")
        Log.debug("   ephemeralPublicKey: \(message.ephemeralPublicKey.count) bytes", category: "CryptoManager")
        Log.debug("   content length: \(message.content.count) chars", category: "CryptoManager")

        let plaintext: String
        do {
            plaintext = try messageCrypto.decryptMessage(
                message,
                contactIdOverride: contactIdOverride,
                core: orchestratorCore,
                restoreSession: { [weak self] userId in
                    Log.info("🔄 Session not in memory, attempting restore: \(userId)", category: "CryptoManager")
                    return self?.restoreSession(for: userId) ?? false
                },
                saveSession: { [weak self] userId in
                    self?.saveSessionToKeychain(for: userId)
                },
                archiveSession: { [weak self] userId, reason in
                    Log.debug("🔄 Archiving corrupted session for \(userId) to allow reinitialization", category: "CryptoManager")
                    self?.archiveSession(for: userId, reason: reason)
                },
                tryDecryptWithArchived: { [weak self] message in
                    guard let self = self else {
                        throw CryptoManagerError.decryptionFailed
                    }
                    let plaintext = try self.tryDecryptWithArchivedSessions(message: message)
                    Log.info("✅ Successfully decrypted with archived session!", category: "CryptoManager")
                    return plaintext
                }
            )
        } catch {
            Log.error("❌ Rust core decryptMessage failed for \(message.id.prefix(8))… msgNum=\(message.messageNumber): \(error)", category: "CryptoManager")
            throw error
        }

        Log.info("✅ Message decrypted successfully (messageNumber: \(message.messageNumber), plaintext: \(plaintext.count) chars)", category: "CryptoManager")
        return plaintext
    }
    
    /// Try to decrypt message with archived sessions
    /// Returns plaintext if successful, throws if all archives fail
    private func tryDecryptWithArchivedSessions(message: ChatMessage) throws -> String {
        guard let core = orchestratorCore else {
            throw CryptoManagerError.coreNotInitialized
        }
        
        // Load archives from memory or Keychain
        let archives = archiveManager.loadArchives(for: message.from)
        
        guard let archives = archives, !archives.isEmpty else {
            Log.debug("📦 No archived sessions available for \(message.from)", category: "CryptoManager")
            throw CryptoManagerError.sessionNotFound
        }
        
        Log.info("📦 Trying \(archives.count) archived sessions for \(message.from)", category: "CryptoManager")

        // Snapshot the active session so we can restore it if all archives fail.
        // Without this, each failed import permanently overwrites the Rust core state.
        let activeSessionSnapshot = try? Data(core.exportSession(contactId: message.from))

        // Try each archived session (newest first - already ordered)
        for (index, archive) in archives.enumerated().reversed() {
            do {
                // Temporarily restore archived session to Rust core.
                // importSession handles CFE binary (new) and legacy JSON (old) archives.
                _ = try core.importSession(contactId: message.from, data: [UInt8](archive.sessionData))
                
                // Try to decrypt
                let plaintext = try core.decryptMessage(
                    contactId: message.from,
                    ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                    messageNumber: message.messageNumber,
                    content: message.content
                )
                
                Log.info("✅ Decrypted with archived session #\(index) (archived at: \(archive.archivedAt))", category: "CryptoManager")
                
                // Success! Save the now-active session
                saveSessionToKeychain(for: message.from)
                
                // Remove from archives (it's valid again)
                archiveManager.restoreArchiveToCurrent(for: message.from, index: index)
                
                Log.info("♻️ Restored archived session as current", category: "CryptoManager")
                
                return plaintext
                
            } catch {
                Log.debug("❌ Archive #\(index) failed: \(error)", category: "CryptoManager")
                continue
            }
        }

        // All archives failed — restore the original active session into Rust core.
        if let snap = activeSessionSnapshot {
            _ = try? core.importSession(contactId: message.from, data: [UInt8](snap))
        }
        
        Log.info("⚠️ All \(archives.count) archived sessions failed to decrypt", category: "CryptoManager")
        throw CryptoManagerError.decryptionFailed
    }
}

// MARK: - Error Types

/// CryptoManager-specific errors (wraps UniFFI CryptoError)
enum CryptoManagerError: Error, LocalizedError {
    case coreNotInitialized
    case sessionNotFound
    case sessionInitializationFailed
    case encryptionFailed
    case decryptionFailed
    case invalidCiphertext
    case invalidKeyData
    /// Kyber OTPK secret is missing locally for the given key ID.
    /// Throwing this forces session init to fail, which triggers END_SESSION + clean re-init
    /// instead of silently establishing a PQ-diverged session that will break on msg1+.
    case pqxdhOtpkMissing(UInt32)

    var errorDescription: String? {
        switch self {
        case .coreNotInitialized:
            return "Crypto core is not initialized"
        case .sessionNotFound:
            return "No session found for this user"
        case .sessionInitializationFailed:
            return "Failed to initialize session"
        case .encryptionFailed:
            return "Failed to encrypt message"
        case .decryptionFailed:
            return "Failed to decrypt message"
        case .invalidCiphertext:
            return "Invalid ciphertext format"
        case .invalidKeyData:
            return "Invalid key data"
        case .pqxdhOtpkMissing(let id):
            return "Kyber OTPK id=\(id) not found locally — session init failed to prevent PQ root key divergence"
        }
    }
}

// MARK: - Session Archive

/// Reason for archiving a session
enum ArchiveReason: String, Codable {
    case decryptionFailed = "decryption_failed"
    case endSessionReceived = "end_session_received"
    case manualReset = "manual_reset"
    case preKeyChanged = "prekey_changed"
    /// Remote peer re-keyed: messageNumber=0 arrived for an existing session.
    case remoteRekeying = "remote_rekeying"
}

/// Archived session data for fallback decryption.
/// Stored in CFE binary format (MessagePack + header). Legacy archives written as
/// JSON strings are transparently read back via the migration initializer and fed
/// to `import_session`, which has a built-in `LegacyJson` fallback.
struct SessionArchive: Codable {
    let sessionData: Data  // CFE binary (new) or UTF-8 JSON bytes (legacy)
    let archivedAt: Date
    let reason: ArchiveReason

    init(sessionData: Data, archivedAt: Date, reason: ArchiveReason) {
        self.sessionData = sessionData
        self.archivedAt = archivedAt
        self.reason = reason
    }

    // MARK: Migration — read archives written with the old `sessionJson: String` field
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        archivedAt = try c.decode(Date.self, forKey: .archivedAt)
        reason    = try c.decode(ArchiveReason.self, forKey: .reason)
        if let data = try c.decodeIfPresent(Data.self, forKey: .sessionData) {
            sessionData = data
        } else if let json = try c.decodeIfPresent(String.self, forKey: .sessionJson) {
            // Old format: JSON string → store as UTF-8 bytes; importSession handles LegacyJson
            sessionData = Data(json.utf8)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: c.codingPath,
                                      debugDescription: "SessionArchive missing sessionData and sessionJson"))
        }
    }

    // Explicit Encodable: always write the new `sessionData` key
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionData,  forKey: .sessionData)
        try c.encode(archivedAt,   forKey: .archivedAt)
        try c.encode(reason,       forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionData, sessionJson, archivedAt, reason
    }

    /// Check if archive is expired (older than retention period)
    func isExpired(retentionDays: Int) -> Bool {
        let expirationDate = Calendar.current.date(byAdding: .day, value: retentionDays, to: archivedAt) ?? Date()
        return Date() > expirationDate
    }
}

// MARK: - Data Hex Extension

fileprivate extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
    
    var hexString: String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
