//
//  PQCKeyManager.swift
//  Construct Messenger
//
//  Manages ML-KEM-768 (Kyber) keypair lifecycle for PQXDH:
//  - Key generation at registration/first launch
//  - Secure storage in Keychain
//  - Upload to key server alongside classic X25519 keys
//  - Retrieval of secret key for decapsulation on incoming sessions
//
//  Migration status (M3):
//  - mlkem768Keygen / mlkem768Encapsulate / mlkem768Decapsulate → already Rust ✅
//  - signBundleData → already Rust (ClassicCryptoCore) ✅
//  - pendingPQContributions + NSLock → replaced by RustPQContributions ✅
//  - Keychain storage (SPK/OTPK) → stays Swift until PlatformBridge (M4)
//

import Foundation
import GRPCCore

/// Manages the ML-KEM-768 keypair used in PQXDH (post-quantum X3DH).
///
/// The Kyber Signed Pre-Key (Kyber SPK) provides HNDL (Harvest Now Decrypt Later)
/// protection: even if X25519 is broken by a future quantum computer, sessions
/// where PQXDH was used remain secure.
final class PQCKeyManager {
    static let shared = PQCKeyManager()
    private init() {}

    // MARK: - Deferred PQ contributions
    // Rust-backed thread-safe store replacing [String: [UInt8]] + NSLock.
    // Stores KEM shared secret between encapsulate (session init) and msg0 send.
    // Applied only after msg0 is encrypted with classic state.
    private let rustContributions = RustPqContributions()

    // Keychain key for the bundled CFE snapshot of all deferred contributions.
    private static let kyberSessionStateCFEKey = "construct.kyber_session_state"

    // MARK: - Keychain Keys

    private let kyberSPKPublicKey = "construct.kyber.spk.public"
    private let kyberSPKSecretKey = "construct.kyber.spk.secret"
    private let kyberSPKIdKey     = "construct.kyber.spk.id"

    // MARK: - Key Generation

    /// Generate and store a new ML-KEM-768 Signed Pre-Key.
    ///
    /// Called during registration or when rotating keys. Stores both public and
    /// secret keys in Keychain. Returns the public key bytes and assigned key ID
    /// ready for upload.
    ///
    /// - Parameter keyId: Key ID to assign (should be monotonically increasing)
    /// - Returns: `(publicKey: Data, keyId: UInt32)` for uploading to server
    @discardableResult
    func generateAndStoreKyberSPK(keyId: UInt32 = 1) throws -> (publicKey: Data, keyId: UInt32) {
        let keyPair = try mlkem768Keygen()
        let pubKeyData = Data(keyPair.publicKey)
        let secKeyData = Data(keyPair.secretKey)

        guard KeychainManager.shared.saveData(pubKeyData, forKey: kyberSPKPublicKey),
              KeychainManager.shared.saveData(secKeyData, forKey: kyberSPKSecretKey),
              KeychainManager.shared.saveData(Data(withUInt32: keyId), forKey: kyberSPKIdKey) else {
            throw PQCError.keychainSaveFailed
        }

        Log.info("PQC: Generated ML-KEM-768 Kyber SPK, keyId=\(keyId), pk=\(pubKeyData.count)B", category: "PQC")
        return (publicKey: pubKeyData, keyId: keyId)
    }

    // MARK: - Two-phase Kyber SPK generation (for atomic rotation)

    /// Phase 1: Generate a new Kyber SPK in memory WITHOUT writing to Keychain.
    ///
    /// Used during atomic SPK rotation: generate both keys first, send a single
    /// RotateSignedPreKeyRequest RPC with both, and only commit to Keychain
    /// (via `commitKyberSPK`) after the server confirms success.
    ///
    /// - Returns: In-memory key material + the next key ID to use.
    func generateKyberSPKInMemory() throws -> (publicKey: Data, secretKey: Data, keyId: UInt32) {
        let keyPair = try mlkem768Keygen()
        let pubKeyData = Data(keyPair.publicKey)
        let secKeyData = Data(keyPair.secretKey)
        let keyId = kyberSPKId() + 1
        return (publicKey: pubKeyData, secretKey: secKeyData, keyId: keyId)
    }

    /// Phase 2: Commit a previously-generated in-memory Kyber SPK to Keychain.
    ///
    /// Call ONLY after the server has confirmed the rotation RPC succeeded.
    func commitKyberSPK(publicKey: Data, secretKey: Data, keyId: UInt32) throws {
        guard KeychainManager.shared.saveData(publicKey, forKey: kyberSPKPublicKey),
              KeychainManager.shared.saveData(secretKey, forKey: kyberSPKSecretKey),
              KeychainManager.shared.saveData(Data(withUInt32: keyId), forKey: kyberSPKIdKey) else {
            throw PQCError.keychainSaveFailed
        }
        Log.info("PQC: Committed rotated Kyber SPK to Keychain, keyId=\(keyId)", category: "PQC")
    }

    // MARK: - Retrieval

    /// Retrieve the stored Kyber SPK public key for upload.
    func kyberSPKPublic() throws -> Data {
        guard let data = KeychainManager.shared.loadData(forKey: kyberSPKPublicKey) else {
            throw PQCError.keyNotFound
        }
        return data
    }

    /// Retrieve the stored Kyber SPK secret key for decapsulation.
    func kyberSPKSecret() throws -> Data {
        guard let data = KeychainManager.shared.loadData(forKey: kyberSPKSecretKey) else {
            throw PQCError.keyNotFound
        }
        return data
    }

    /// Retrieve the stored Kyber SPK key ID.
    func kyberSPKId() -> UInt32 {
        guard let data = KeychainManager.shared.loadData(forKey: kyberSPKIdKey) else { return 1 }
        return data.toUInt32() ?? 1
    }

    /// Returns true if a Kyber SPK is already stored in Keychain.
    var hasStoredKey: Bool {
        KeychainManager.shared.loadData(forKey: kyberSPKPublicKey) != nil
    }

    // MARK: - One-time migration for existing users

    /// UserDefaults key for the one-time PQC migration flag.
    /// Bump the suffix (v2, v3…) only if keys ever need to be regenerated and re-uploaded.
    private static let migrationDoneKey = "pqcKyberSPKMigrationV1Done"

    /// Generate, sign and upload Kyber SPK if it hasn't been done yet on this device.
    ///
    /// Safe to call on every app launch — returns immediately if the migration flag is already set.
    /// On network failure the flag is NOT set, so the next launch will retry automatically.
    static func migrateIfNeeded(deviceId: String) async {
        guard !UserDefaults.standard.bool(forKey: migrationDoneKey) else { return }

        // Attempt 0: generate key in Keychain + upload
        do {
            guard CryptoManager.shared.orchestratorCore != nil else { return }
            let spkId = shared.kyberSPKId()
            let (spkPublicKey, _) = try shared.generateAndStoreKyberSPK(keyId: spkId)
            let spkSig = try signKyberKey(publicKey: spkPublicKey)
            _ = try await generateAndUploadKyberOtpks(
                count: 20,
                deviceId: deviceId,
                kyberSignedPreKey: (keyId: spkId, publicKey: spkPublicKey, signature: spkSig)
            )
            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            Log.info("PQC: Kyber SPK migration complete", category: "PQC")
            return
        } catch {
            guard let rpcError = error as? RPCError, rpcError.code == .unavailable else {
                Log.error("PQC: Kyber SPK migration failed (will retry next launch): \(error)", category: "PQC")
                return
            }
            Log.info("PQC: Kyber SPK upload unavailable — will retry (key already in Keychain)", category: "PQC")
        }

        // Attempts 1-2: key is already stored, retry upload with fresh OTPKs
        // (uploadKyberSPK alone is rejected by server — pre_keys/kyber_pre_keys must not both be empty)
        guard CryptoManager.shared.orchestratorCore != nil else { return }
        for attempt in 1...2 {
            let delay = Double(attempt) * 2.0
            try? await Task.sleep(for: .seconds(delay))
            do {
                let spkId = shared.kyberSPKId()
                let spkPublicKey = try shared.kyberSPKPublic()
                let spkSig = try signKyberKey(publicKey: spkPublicKey)
                _ = try await generateAndUploadKyberOtpks(
                    count: 20,
                    deviceId: deviceId,
                    kyberSignedPreKey: (keyId: spkId, publicKey: spkPublicKey, signature: spkSig)
                )
                UserDefaults.standard.set(true, forKey: migrationDoneKey)
                Log.info("PQC: Kyber SPK migration complete (retry \(attempt))", category: "PQC")
                return
            } catch {
                if attempt == 2 {
                    Log.error("PQC: Kyber SPK migration failed after retries (will retry next launch): \(error)", category: "PQC")
                }
            }
        }
    }

    /// Generate, sign and upload Kyber SPK to the key server.
    ///
    /// Called at registration (new users) and by `migrateIfNeeded` (existing users).
    static func uploadKyberSPK(deviceId: String) async throws {
        guard CryptoManager.shared.orchestratorCore != nil else {
            throw PQCError.coreNotInitialized
        }

        let keyId = shared.kyberSPKId()
        let (publicKey, _) = try shared.generateAndStoreKyberSPK(keyId: keyId)

        // Sign the public key with correct prologue
        let sigData = try signKyberKey(publicKey: publicKey)

        _ = try await KeyServiceClient.shared.uploadPreKeys(
            deviceId: deviceId,
            kyberSignedPreKey: (keyId: keyId, publicKey: publicKey, signature: sigData)
        )
        Log.info("PQC: Kyber SPK uploaded (keyId=\(keyId), pk=\(publicKey.count)B)", category: "PQC")
    }

    // MARK: - Kyber Key Signing

    /// Build the sign message with prologue for any Kyber key.
    private static func kyberSignMessage(publicKey: Data) -> [UInt8] {
        var msg = Data()
        msg.append(contentsOf: "KonstruktX3DH-v1".utf8)
        msg.append(contentsOf: [0x00, 0x10])  // suite_id = 0x10 (ML-KEM-1024 / Kyber) big-endian
        msg.append(publicKey)
        return [UInt8](msg)
    }

    /// Sign a Kyber public key with the device Ed25519 identity key (serialized via coreLock).
    static func signKyberKey(publicKey: Data) throws -> Data {
        try CryptoManager.shared.signBundleData(kyberSignMessage(publicKey: publicKey))
    }

    // MARK: - Kyber OTPK Management

    private static let otpkNextKeyIdKey = "construct.kyber.otpk.nextKeyId"
    private static let keyIdAllocationLock = NSLock()
    private static func otpkKeychainKey(_ keyId: UInt32) -> String { "construct.kyber.otpk.sk.\(keyId)" }

    /// Allocate `count` sequential key IDs for a new Kyber OTPK batch.
    private static func allocateKeyIds(count: Int) -> [UInt32] {
        keyIdAllocationLock.lock()
        defer { keyIdAllocationLock.unlock() }
        let start = UInt32(UserDefaults.standard.integer(forKey: otpkNextKeyIdKey))
        UserDefaults.standard.set(Int(start) + count, forKey: otpkNextKeyIdKey)
        return (0..<count).map { start + UInt32($0) }
    }

    /// Load a Kyber OTPK secret key from Keychain by key ID. Returns nil if not found.
    static func kyberOtpkSecret(forKeyId keyId: UInt32) -> Data? {
        KeychainManager.shared.loadData(forKey: otpkKeychainKey(keyId))
    }

    /// Delete a Kyber OTPK secret key from Keychain (burn-on-use after decapsulation).
    static func deleteKyberOtpk(keyId: UInt32) {
        KeychainManager.shared.deleteData(forKey: otpkKeychainKey(keyId))
    }

    /// Generate `count` Kyber OTPKs, sign, store secrets in Keychain, upload to server.
    /// Optionally includes a Kyber SPK in the same request (avoids a separate upload call).
    /// Returns number of Kyber OTPKs now on server.
    @discardableResult
    static func generateAndUploadKyberOtpks(
        count: Int = 50,
        deviceId: String,
        kyberSignedPreKey: (keyId: UInt32, publicKey: Data, signature: Data)? = nil
    ) async throws -> UInt32 {
        guard CryptoManager.shared.orchestratorCore != nil else { throw PQCError.coreNotInitialized }
        let keyIds = allocateKeyIds(count: count)
        var uploadBatch: [(keyId: UInt32, publicKey: Data, signature: Data)] = []
        for keyId in keyIds {
            let kp = try mlkem768Keygen()
            let pubKeyData = Data(kp.publicKey)
            guard KeychainManager.shared.saveData(Data(kp.secretKey), forKey: otpkKeychainKey(keyId)) else {
                Log.error("PQC: failed to save Kyber OTPK secret keyId=\(keyId)", category: "PQC")
                continue
            }
            let sigData = try signKyberKey(publicKey: pubKeyData)
            uploadBatch.append((keyId: keyId, publicKey: pubKeyData, signature: sigData))
        }
        guard !uploadBatch.isEmpty else { throw PQCError.keychainSaveFailed }
        let (_, kyberCount) = try await KeyServiceClient.shared.uploadPreKeys(
            deviceId: deviceId,
            kyberSignedPreKey: kyberSignedPreKey,
            kyberOneTimePreKeys: uploadBatch
        )
        Log.info("PQC: Uploaded \(uploadBatch.count) Kyber OTPKs, server count=\(kyberCount)", category: "PQC")
        return kyberCount
    }


    /// Encapsulate to recipient's Kyber SPK and store the shared secret for later.
    /// The actual `applyPqContribution` is deferred until after msg0 is encrypted,
    /// so that msg0 uses classic-only DR state (matching the receiver expectation).
    ///
    /// The shared secret is kept in the Rust in-memory cache AND persisted to Keychain
    /// so it survives app crashes between encapsulation and application.
    ///
    /// Call `applyDeferredPQContribution` after msg0 has been encrypted.
    func encapsulateAndDefer(kyberSPKPublic: Data, contactId: String) throws -> Data {
        let encapsulation = try mlkem768Encapsulate(publicKey: [UInt8](kyberSPKPublic))
        rustContributions.storeDeferred(contactId: contactId, sharedSecret: encapsulation.sharedSecret)
        // Register with OrchestratorCore's PQContributionManager (single source of truth for CFE).
        // Falls back to per-entry Keychain backup if core is unavailable.
        if !CryptoManager.shared.registerPqDeferred(
            contactId: contactId,
            otpkId: 0,   // otpk_id not tracked at this layer; 0 = unknown
            sharedSecret: encapsulation.sharedSecret
        ) == false {
            _ = KeychainManager.shared.saveData(
                Data(encapsulation.sharedSecret),
                forKey: "construct.pq_deferred.\(contactId)"
            )
        }
        Log.info("PQC: PQXDH encapsulated for \(contactId.prefix(8))..., ct=\(encapsulation.ciphertext.count)B (deferred + persisted)", category: "PQC")
        return Data(encapsulation.ciphertext)
    }

    /// Apply the deferred Kyber shared secret to the DR session (serialized via coreLock).
    /// Must be called after msg0 is encrypted, before msg1 is encrypted.
    /// Recovers from Keychain if the in-memory cache was lost (e.g., after a crash).
    func applyDeferredPQContribution(contactId: String) throws {
        let key = "construct.pq_deferred.\(contactId)"
        // Prefer in-memory cache; fall back to Keychain if cache was lost (e.g., after a crash).
        var ss = rustContributions.takeDeferred(contactId: contactId)
        if ss == nil, let persisted = KeychainManager.shared.loadData(forKey: key) {
            ss = [UInt8](persisted)
            Log.info("PQC: Deferred PQXDH recovered from Keychain for \(contactId.prefix(8))…", category: "PQC")
        }
        guard let sharedSecret = ss else { return }
        // Delete per-entry Keychain backup regardless — contribution is consumed exactly once.
        KeychainManager.shared.deleteData(forKey: key)
        try CryptoManager.shared.applyPqContribution(contactId: contactId, kemSharedSecret: sharedSecret)
        // Persist updated CFE snapshot after contribution is consumed.
        CryptoManager.shared.savePQCSnapshot()
        Log.info("PQC: Deferred PQXDH applied for \(contactId.prefix(8))...", category: "PQC")
    }

    /// Discard any pending PQ contribution (e.g., when kem cannot be included in the message).
    func clearPendingContribution(for contactId: String) {
        rustContributions.clear(contactId: contactId)
        KeychainManager.shared.deleteData(forKey: "construct.pq_deferred.\(contactId)")
        CryptoManager.shared.savePQCSnapshot()
    }

    // MARK: - CFE Snapshot Persistence

    /// Save the full Kyber session state as a single CFE blob in Keychain.
    /// Called after any contribution is registered or consumed.
    static func saveCFESnapshot(to core: OrchestratorCore) {
        guard let blob = try? core.exportKyberSessionState(),
              !blob.isEmpty else { return }
        _ = KeychainManager.shared.saveData(
            Data(blob),
            forKey: kyberSessionStateCFEKey
        )
    }

    /// Restore the Kyber session state from a previously saved CFE blob.
    /// Call at app startup, before any session crypto.
    static func loadCFESnapshot(into core: OrchestratorCore) {
        guard let data = KeychainManager.shared.loadData(forKey: kyberSessionStateCFEKey),
              !data.isEmpty else { return }
        do {
            try core.importKyberSessionState(data: [UInt8](data))
            Log.info("PQC: Kyber session state restored from CFE snapshot (\(data.count)B)", category: "PQC")
        } catch {
            Log.error("PQC: Failed to restore Kyber session state: \(error)", category: "PQC")
        }
    }

    // MARK: - PQXDH Receiver: Decapsulate + Strengthen Session

    /// Perform receiver-side PQXDH: decapsulate the received KEM ciphertext using
    /// our Kyber SPK secret key (or an OTPK secret key override), then strengthen
    /// the Double Ratchet session (serialized via coreLock).
    ///
    /// - Parameters:
    ///   - kemCiphertext: The `PreKeySignalMessage.kemCiphertext` from the sender
    ///   - contactId: Session contact ID
    ///   - secretKeyOverride: Optional OTPK secret key; nil = use Kyber SPK
    func decapsulateAndStrengthen(
        kemCiphertext: Data,
        contactId: String,
        secretKeyOverride: Data? = nil
    ) throws {
        let spkSecret = try secretKeyOverride ?? kyberSPKSecret()
        let sharedSecret = try mlkem768Decapsulate(
            secretKey: [UInt8](spkSecret),
            ciphertext: [UInt8](kemCiphertext)
        )
        try CryptoManager.shared.applyPqContribution(contactId: contactId, kemSharedSecret: sharedSecret)
        Log.info("PQC: PQXDH decapsulated for \(contactId.prefix(8))...", category: "PQC")
    }
}

// MARK: - Errors

enum PQCError: Error, ApplicationLayerError {
    case keychainSaveFailed
    case keyNotFound
    case coreNotInitialized
    case signatureFailed
}

// MARK: - Data Helpers

private extension Data {
    init(withUInt32 value: UInt32) {
        var v = value
        self = Swift.withUnsafeBytes(of: &v) { Data($0) }
    }

    func toUInt32() -> UInt32? {
        guard count == 4 else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}
