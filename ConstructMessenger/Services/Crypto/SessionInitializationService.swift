import Foundation
import os.log

/// Errors specific to the session-init layer (distinct from CryptoManagerError).
enum SessionError: Error, LocalizedError {
    /// Server returned a bundle whose SPK rotation epoch is older than the last
    /// seen epoch for this contact — possible replay attack.
    case staleSPKBundle(epoch: UInt32, knownEpoch: UInt32)

    var errorDescription: String? {
        switch self {
        case .staleSPKBundle(let epoch, let knownEpoch):
            return "SPK bundle replay: received epoch \(epoch) ≤ known epoch \(knownEpoch)"
        }
    }
}

/// Service responsible for session initialization with retry logic and queue management.
/// Singleton: the pending KEM ciphertexts / OTPK IDs must be visible across all
/// call-sites (SessionCoordinator prewarm, ChatViewModel send, auto-resend, etc.).
@MainActor
class SessionInitializationService {

    static let shared = SessionInitializationService()
    private init() {}

    // MARK: - PQC pending KEM ciphertexts

    /// Keyed by userId; holds the kem_ciphertext from a fresh PQXDH handshake
    /// until it can be attached to the outgoing first message.
    private var pendingKemCiphertexts: [String: Data] = [:]

    /// Keyed by userId; holds the Kyber OTPK ID used in a fresh PQXDH handshake.
    private var pendingKyberOtpkIds: [String: UInt32] = [:]

    /// Consume (and remove) the pending KEM ciphertext for a contact, if any.
    /// Also applies the deferred PQXDH contribution to the DR session — msg0 was
    /// already encrypted with classic-only state, so this is the correct moment.
    /// Returns nil (skipping PQ entirely) if the contribution cannot be applied,
    /// so both sides stay in sync: neither applies PQXDH.
    func consumeKemCiphertext(for userId: String) -> Data? {
        guard let kem = pendingKemCiphertexts.removeValue(forKey: userId) else { return nil }
        guard let core = CryptoManager.shared.orchestratorCore else {
            Log.error("⚠️ PQC: Core nil at KEM consumption — skipping PQ for \(userId.prefix(8))...", category: "SessionInit")
            PQCKeyManager.shared.clearPendingContribution(for: userId)
            return nil  // Don't send kem; receiver won't apply PQ either → both stay classic
        }
        do {
            try PQCKeyManager.shared.applyDeferredPQContribution(contactId: userId, core: core)
            CryptoManager.shared.saveSessionToKeychainPublic(for: userId)
            return kem
        } catch {
            Log.error("⚠️ PQC: Failed to apply deferred PQ for \(userId.prefix(8))...: \(error) — skipping PQ", category: "SessionInit")
            PQCKeyManager.shared.clearPendingContribution(for: userId)
            return nil  // Don't send kem; receiver won't apply PQ either → both stay classic
        }
    }

    /// Consume (and remove) the pending Kyber OTPK ID for a contact (0 if none).
    func consumeKyberOtpkId(for userId: String) -> UInt32 {
        defer { pendingKyberOtpkIds.removeValue(forKey: userId) }
        return pendingKyberOtpkIds[userId] ?? 0
    }
    
    // MARK: - Public Methods
    
    /// Fetch public key bundle with exponential backoff retry
    func fetchPublicKeyWithRetry(
        userId: String,
        deviceId: String? = nil,
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0
    ) async throws -> PublicKeyBundleData {
        var lastError: Error?
        var delay = initialDelay
        
        for attempt in 1...maxAttempts {
            do {
                Log.info("🔑 SESSION_STATE[fetch_bundle_attempt_\(attempt)]: userId=\(userId.prefix(8))..., deviceId=\(deviceId?.prefix(8) ?? "nil")...", category: "SessionInit")
                let keyBundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId, deviceId: deviceId)
                Log.info("✅ SESSION_STATE[fetch_bundle_success]: userId=\(userId.prefix(8))..., hasVerifyingKey=\(!keyBundle.verifyingKey.isEmpty)", category: "SessionInit")
                return keyBundle
            } catch {
                lastError = error
                Log.error("⚠️ SESSION_STATE[fetch_bundle_failed]: attempt=\(attempt)/\(maxAttempts), error=\(error) (\(type(of: error)))", category: "SessionInit")
                
                if attempt < maxAttempts {
                    Log.info("⏳ Retrying public key fetch in \(delay)s...", category: "SessionInit")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= 2  // Exponential backoff: 1s, 2s, 4s
                }
            }
        }
        
        Log.error("❌ SESSION_STATE[fetch_bundle_exhausted]: userId=\(userId.prefix(8))..., allAttemptsFailed", category: "SessionInit")
        throw lastError ?? NetworkError.connectionFailed
    }
    
    /// Initialize a session with a recipient using their public key bundle
    @discardableResult
    func initializeSession(
        userId: String,
        bundle: PublicKeyBundleData,
        deleteExisting: Bool = true
    ) throws -> Data? {
        // Proactively delete stale session if requested
        if deleteExisting {
            if CryptoManager.shared.hasSession(for: userId) {
                CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
                Log.info("🗑️ Proactively deleted any existing session for \(userId) before initialization.", category: "SessionInit")
            }
        }

        // Epoch replay-attack check: reject bundles where the server's monotonic
        // rotation counter has not advanced beyond what we last saw for this contact.
        // (Skip when epoch == 0, which means the server hasn't migrated yet.)
        if bundle.spkRotationEpoch > 0 {
            let knownEpoch = UInt32(UserDefaults.standard.integer(forKey: "construct.spk_epoch.\(userId)"))
            if bundle.spkRotationEpoch < knownEpoch {
                Log.error("⚠️ SESSION_STATE[spk_replay_rejected]: epoch=\(bundle.spkRotationEpoch) < known=\(knownEpoch) for \(userId.prefix(8))… — possible SPK replay attack", category: "SessionInit")
                throw SessionError.staleSPKBundle(epoch: bundle.spkRotationEpoch, knownEpoch: knownEpoch)
            }
            UserDefaults.standard.set(Int(bundle.spkRotationEpoch), forKey: "construct.spk_epoch.\(userId)")
        }

        let bundleWithSuite = (
            identityPublic: bundle.identityPublic,
            signedPrekeyPublic: bundle.signedPrekeyPublic,
            signature: bundle.signature,
            verifyingKey: bundle.verifyingKey,
            suiteId: String(bundle.suiteId)
        )

        let otpkPublic = bundle.oneTimePreKeyPublic
        let otpkId = bundle.oneTimePreKeyId

        do {
            let result = try CryptoManager.shared.initializeSession(
                for: userId,
                recipientBundle: bundleWithSuite,
                oneTimePreKeyPublic: otpkPublic,
                oneTimePreKeyId: otpkId,
                kyberPreKeyPublic: bundle.kyberPreKeyPublic,
                kyberOneTimePreKeyPublic: bundle.kyberOneTimePreKeyPublic,
                kyberOneTimePreKeyId: bundle.kyberOneTimePreKeyId,
                spkUploadedAt: bundle.spkUploadedAt,
                spkRotationEpoch: bundle.spkRotationEpoch,
                kyberSpkUploadedAt: bundle.kyberSpkUploadedAt,
                kyberSpkRotationEpoch: bundle.kyberSpkRotationEpoch
            )
            Log.info("✅ Session initialized as INITIATOR for \(userId)", category: "SessionInit")
            if let kem = result.kemCiphertext {
                pendingKemCiphertexts[userId] = kem
            }
            if result.kyberOtpkId > 0 {
                pendingKyberOtpkIds[userId] = result.kyberOtpkId
            }
            return result.kemCiphertext
        } catch {
            Log.error("❌ Session init failed for \(userId): \(error)", category: "SessionInit")
            Log.error("   bundle.suiteId=\(bundle.suiteId), identityPublic.len=\(bundle.identityPublic.count), signedPrekeyPublic.len=\(bundle.signedPrekeyPublic.count)", category: "SessionInit")
            throw error
        }
    }
    
    /// Proactively initialize session for a user (fetch bundle + initialize)
    func initializeSessionProactively(
        userId: String,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) async {
        Log.info("🔐 SESSION_STATE[proactive_init_start]: userId=\(userId.prefix(8))...", category: "SessionInit")
        
        do {
            // Fetch bundle with retry
            let bundle = try await fetchPublicKeyWithRetry(userId: userId)
            
            // Initialize sending session (also stores pending KEM/OTPK IDs internally)
            _ = try initializeSession(userId: userId, bundle: bundle, deleteExisting: true)

            Log.info("✅ SESSION_STATE[proactive_init_success]: userId=\(userId.prefix(8))...", category: "SessionInit")
            
            // Notify success on main actor
            await MainActor.run {
                onSuccess()
            }
            
        } catch {
            Log.error("❌ SESSION_STATE[proactive_init_failed]: userId=\(userId.prefix(8))..., error=\(error.localizedDescription)", category: "SessionInit")
            
            // Notify failure on main actor
            await MainActor.run {
                onFailure(error)
            }
        }
    }
}
