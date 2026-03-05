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

class CryptoManager {
    static let shared = CryptoManager()

    // UniFFI ClassicCryptoCore object (automatically managed by Arc in Rust)
    // ⚠️ Internal access for InviteGenerator (needs to export keys)
    internal var core: ClassicCryptoCore?
    private let coreProvider = CryptoCoreProvider()

    // Session storage
    private let sessionStore = SessionStore()
    
    // MARK: - Session Archive
    private let archiveManager = SessionArchiveManager()
    private let messageCrypto = MessageCryptoService()
    private let sessionInitService = CryptoSessionInitializationService()
    private let registrationBundleService = RegistrationBundleService()
    private let sessionRestoreService = SessionRestoreService()
    private let bundleSignatureService = BundleSignatureService()
    
    // MARK: - Prekey ID Tracking
    private let preKeyTracker = PreKeyTrackingStore()
    
    // MARK: - Garbage Collection
    
    /// Timer for periodic archive cleanup (24 hours)
    private var gcTimer: Timer?
    
    /// GC interval (24 hours)
    private let gcIntervalSeconds: TimeInterval = 24 * 60 * 60

    private init() {
        self.core = coreProvider.loadCore()

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
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }

        let keysJSON = try core.exportPrivateKeysJson()
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
        
        // Use existing core if available, otherwise create a new one
        let activeCore: ClassicCryptoCore
        if let core = self.core {
            activeCore = core
        } else {
            activeCore = try createCryptoCore()
            self.core = activeCore
        }
        
        // Export registration bundle (contains all public keys)
        let bundleJson = try activeCore.exportRegistrationBundleJson()
        Log.debug("📦 Registration bundle: \(bundleJson.prefix(200))...", category: "CryptoManager")
        
        // Export private keys to extract what we need
        let privateKeysJson = try activeCore.exportPrivateKeysJson()
        Log.debug("🔐 Private keys JSON: \(privateKeysJson.prefix(200))...", category: "CryptoManager")

        // Persist the new core keys so the app uses the same keypair after registration
        let saved = KeychainManager.shared.savePrivateKeysJson(privateKeysJson)
        if saved {
            Log.info("✅ Saved registration private keys JSON to Keychain", category: "CryptoManager")
        } else {
            Log.error("⚠️ Failed to save registration private keys JSON to Keychain", category: "CryptoManager")
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
        sessionStore.saveSessionToKeychain(userId: userId, core: core, onLog: { message in
            if message.hasPrefix("💾") || message.hasPrefix("⚠️") {
                Log.debug(message, category: "CryptoManager")
            } else {
                Log.error(message, category: "CryptoManager")
            }
        })
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
        guard core != nil else {
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

    /// Restore a single session (used for lazy loading)
    @discardableResult
    func restoreSession(for userId: String) -> Bool {
        sessionStore.restoreSessionIfNeeded(userId: userId, core: core, onLog: { message in
            Log.debug(message, category: "CryptoManager")
        })
    }


    /// Get session ID for a user (for Core Data storage)
    func getSessionId(for userId: String) -> String? {
        return sessionStore.getSessionId(for: userId)
    }

    // MARK: - Key Management

    /// Delete all saved cryptographic keys and sessions (e.g., on account deletion)
    /// After calling this, the app will generate fresh keys on next registration
    func deleteAllCryptoKeys() {
        Log.info("🗑️ Deleting all cryptographic data from Keychain...", category: "CryptoManager")

        // Nullify in-memory core so next registration generates a fresh keypair
        self.core = nil

        // Delete private keys JSON (identity, signed prekey, signing key)
        KeychainManager.shared.deletePrivateKeysJson()

        // Delete all individual keys and ALL sessions
        KeychainManager.shared.deleteAllKeys()

        Log.info("✅ All cryptographic keys and sessions deleted from Keychain", category: "CryptoManager")
        Log.info("ℹ️ On next app launch, fresh cryptographic keys will be generated", category: "CryptoManager")
    }

    // MARK: - Registration

    /// Generates a complete bundle for server registration by calling the Rust core.
    func generateRegistrationBundle() -> RegistrationBundle? {
        guard let bundle = registrationBundleService.generateRegistrationBundle(core: core) else {
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
            let signatureBase64 = try bundleSignatureService.signBundleData(bundleDataJSON, core: core)
            Log.debug("✅ BundleData signed successfully", category: "CryptoManager")
            return signatureBase64
        } catch {
            Log.error("❌ Failed to sign BundleData: \(error)", category: "CryptoManager")
            throw CryptoManagerError.invalidKeyData
        }
    }

    // MARK: - Session Management

    /// Initializes a secure session with a recipient using the Rust core.
    func initializeSession(for userId: String, recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String, suiteId: String), oneTimePreKeyPublic: Data? = nil, oneTimePreKeyId: UInt32? = nil) throws {
        do {
            try sessionInitService.initializeSession(
                for: userId,
                recipientBundle: recipientBundle,
                oneTimePreKeyPublic: oneTimePreKeyPublic,
                oneTimePreKeyId: oneTimePreKeyId,
                core: core,
                sessionStore: sessionStore,
                archiveSession: { [weak self] userId, reason in
                    Log.info("⚠️ Existing session found for \(userId) - archiving before reinitialization to prevent desync", category: "CryptoManager")
                    self?.archiveSession(for: userId, reason: reason)
                },
                saveSession: { [weak self] userId in
                    self?.saveSessionToKeychain(for: userId)
                }
            )
            Log.info("✅ Session initialized for user: \(userId)", category: "CryptoManager")
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
        core?.setLocalUserId(userId: userId)
        Log.debug("🔑 CryptoManager: local user ID set to \(userId)", category: "CryptoManager")
    }

    /// Check if a session exists for a user
    func hasSession(for userId: String) -> Bool {
        let exists = sessionStore.hasSession(for: userId)
        Log.debug("🔑 Session check for \(userId): \(exists ? "EXISTS" : "MISSING")", category: "CryptoManager")
        if exists, let sessionId = sessionStore.getSessionId(for: userId) {
            Log.debug("   Session ID: \(sessionId.prefix(16))...", category: "CryptoManager")
        }
        return exists
    }
    
    /// Get all user IDs with active sessions
    /// Used for sending END_SESSION to all contacts on logout
    func getAllSessionUserIds() -> [String] {
        return sessionStore.allUserIds()
    }

    /// Delete a session for a user (called when deleting a chat)
    /// Archive a session instead of deleting it
    /// Allows fallback decryption for out-of-order messages
    func archiveSession(for userId: String, reason: ArchiveReason) {
        guard let core = core else {
            Log.error("❌ Cannot archive session: Core not initialized", category: "CryptoManager")
            return
        }
        
        Log.info("📦 Archiving session for \(userId), reason: \(reason.rawValue)", category: "CryptoManager")
        
        // 1. Export current session to JSON
        do {
            let sessionJson = try core.exportSessionJson(contactId: userId)
            
            // 2. Create archive entry
            let archive = SessionArchive(
                sessionJson: sessionJson,
                archivedAt: Date(),
                reason: reason
            )
            
            // 3. Add to archives (keep max limit)
            archiveManager.storeArchive(archive, for: userId)
            let count = archiveManager.loadArchives(for: userId)?.count ?? 0
            Log.info("✅ Session archived (\(count) total for user)", category: "CryptoManager")
            
        } catch {
            Log.error("❌ Failed to export session for archiving: \(error)", category: "CryptoManager")
        }
        
        // 5. Remove from active sessions
        sessionStore.removeSession(for: userId)
        Log.info("✅ Removed session from memory: \(userId)", category: "CryptoManager")
        
        // 6. Remove from Rust core
        let removed = core.removeSession(contactId: userId)
        if removed {
            Log.info("✅ Removed session from Rust core: \(userId)", category: "CryptoManager")
        } else {
            Log.info("⚠️ Session not found in Rust core: \(userId)", category: "CryptoManager")
        }
        
        // 7. Remove from Keychain
        KeychainManager.shared.deleteSession(for: userId)
        Log.info("✅ Removed session from Keychain: \(userId)", category: "CryptoManager")
    }
    
    /// Delete a session (legacy - use archiveSession instead)
    @available(*, deprecated, message: "Use archiveSession() instead for better error recovery")
    func deleteSession(for userId: String) {
        // Remove from the Swift session mapping
        if sessionStore.hasSession(for: userId) {
            sessionStore.removeSession(for: userId)
            Log.info("✅ Removed session from memory: \(userId)", category: "CryptoManager")
        }

        // Remove from the Rust core
        if let core = core {
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
                core: core,
                sessionStore: sessionStore,
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
            core: core,
            sessionStore: sessionStore,
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

        Log.debug("✅ ENCRYPT: msgNum=\(components.messageNumber), ephemKey=\(components.ephemeralPublicKey.prefix(8).map { String(format: "%02x", $0) }.joined()), content=\(components.content.prefix(20))...", category: "CryptoManager")

        return components
    }

    /// Decrypt a ChatMessage directly using clean API
    /// Uses clean API - Rust handles all MessagePack internally
    /// Now with Session Archive fallback support
    func decryptMessage(_ message: ChatMessage) throws -> String {
        Log.debug("🔓 Decrypting message \(message.id.prefix(8))... from \(message.from.prefix(8))...", category: "CryptoManager")
        Log.debug("   messageNumber: \(message.messageNumber)", category: "CryptoManager")
        Log.debug("   ephemeralPublicKey: \(message.ephemeralPublicKey.count) bytes", category: "CryptoManager")
        Log.debug("   content length: \(message.content.count) chars", category: "CryptoManager")

        let plaintext = try messageCrypto.decryptMessage(
            message,
            core: core,
            sessionStore: sessionStore,
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

        Log.info("✅ Message decrypted successfully (messageNumber: \(message.messageNumber), plaintext: \(plaintext.count) chars)", category: "CryptoManager")
        return plaintext
    }
    
    /// Try to decrypt message with archived sessions
    /// Returns plaintext if successful, throws if all archives fail
    private func tryDecryptWithArchivedSessions(message: ChatMessage) throws -> String {
        guard let core = core else {
            throw CryptoManagerError.coreNotInitialized
        }
        
        // Load archives from memory or Keychain
        let archives = archiveManager.loadArchives(for: message.from)
        
        guard let archives = archives, !archives.isEmpty else {
            Log.debug("📦 No archived sessions available for \(message.from)", category: "CryptoManager")
            throw CryptoManagerError.sessionNotFound
        }
        
        Log.info("📦 Trying \(archives.count) archived sessions for \(message.from)", category: "CryptoManager")
        
        // Try each archived session (newest first - already ordered)
        for (index, archive) in archives.enumerated().reversed() {
            do {
                // Temporarily restore archived session to Rust core
                _ = try core.importSessionJson(contactId: message.from, sessionJson: archive.sessionJson)
                
                // Try to decrypt
                let plaintext = try core.decryptMessage(
                    sessionId: message.from,  // contactId is used as sessionId
                    ephemeralPublicKey: [UInt8](message.ephemeralPublicKey),
                    messageNumber: message.messageNumber,
                    content: message.content
                )
                
                Log.info("✅ Decrypted with archived session #\(index) (archived at: \(archive.archivedAt))", category: "CryptoManager")
                
                // Success! Restore this session as current
                let suiteId = sessionStore.getSuiteId(for: message.from) ?? 0
                sessionStore.setSession(userId: message.from, sessionId: message.from, suiteId: suiteId)
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

/// Archived session data for fallback decryption
struct SessionArchive: Codable {
    let sessionJson: String  // Exported session from Rust
    let archivedAt: Date
    let reason: ArchiveReason
    
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
