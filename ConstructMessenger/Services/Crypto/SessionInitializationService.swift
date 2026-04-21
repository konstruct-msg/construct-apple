import Foundation
import os.log

/// Errors specific to the session-init layer (distinct from CryptoManagerError).
enum SessionError: Error, LocalizedError {
    /// Server returned a bundle whose SPK rotation epoch is older than the last
    /// seen epoch for this contact — possible replay attack.
    case staleSPKBundle(epoch: UInt32, knownEpoch: UInt32)
    /// Peer's SPK is older than the Rust core's staleness limit.
    /// The peer must open their app to trigger SPK rotation before a session can be established.
    case peerSPKStale(ageDays: Double)

    var errorDescription: String? {
        switch self {
        case .staleSPKBundle(let epoch, let knownEpoch):
            return "SPK bundle replay: received epoch \(epoch) ≤ known epoch \(knownEpoch)"
        case .peerSPKStale(let days):
            return "Contact's encryption keys are \(String(format: "%.0f", days)) days old and need to be refreshed — ask them to open the app"
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
    func initializeSession(
        userId: String,
        bundle: PublicKeyBundleData,
        deleteExisting: Bool = true
    ) throws -> Void {
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
            let knownEpoch = KeychainManager.shared.loadSpkEpoch(for: userId)
            if bundle.spkRotationEpoch < knownEpoch {
                Log.error("⚠️ SESSION_STATE[spk_replay_rejected]: epoch=\(bundle.spkRotationEpoch) < known=\(knownEpoch) for \(userId.prefix(8))… — possible SPK replay attack", category: "SessionInit")
                throw SessionError.staleSPKBundle(epoch: bundle.spkRotationEpoch, knownEpoch: knownEpoch)
            }
            KeychainManager.shared.saveSpkEpoch(bundle.spkRotationEpoch, for: userId)
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
            PerformanceMetrics.shared.start(.sessionInitStart, label: String(userId.prefix(8)))
            try CryptoManager.shared.initializeSession(
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
            PerformanceMetrics.shared.end(.sessionInitStart, endEvent: .sessionInitEnd, label: String(userId.prefix(8)))
            Log.info("✅ Session initialized as INITIATOR for \(userId)", category: "SessionInit")
        } catch {
            let desc = "\(error)"
            // Rust rejects SPK bundles older than 14 days. Parse the age from the error message
            // and surface as peerSPKStale so callers can show a human-readable message.
            if desc.contains("SPK bundle is stale") || desc.contains("spk bundle is stale") {
                let ageDays: Double
                if let match = desc.range(of: #"age=(\d+)s"#, options: .regularExpression) {
                    let ageSecs = Double(desc[match].dropFirst(4).dropLast(1)) ?? 0
                    ageDays = ageSecs / 86400
                } else {
                    ageDays = 14
                }
                Log.error("⚠️ Peer SPK stale for \(userId.prefix(8))… — age ≈ \(String(format: "%.1f", ageDays))d", category: "SessionInit")
                throw SessionError.peerSPKStale(ageDays: ageDays)
            }
            Log.error("❌ Session init failed for \(userId): \(error)", category: "SessionInit")
            Log.error("   bundle.suiteId=\(bundle.suiteId), identityPublic.len=\(bundle.identityPublic.count), signedPrekeyPublic.len=\(bundle.signedPrekeyPublic.count)", category: "SessionInit")
            throw error
        }
    }
    
    /// Proactively initialize session for a user (fetch bundle + initialize).
    ///
    /// When the peer's SPK is stale (`peerSPKStale`), the peer may have just come
    /// online and rotated their keys. The server may not yet reflect the new
    /// `spk_uploaded_at` — in this case we wait `staleSPKRetryDelay` seconds and
    /// retry up to `staleSPKMaxRetries` times before giving up.
    func initializeSessionProactively(
        userId: String,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) async {
        Log.info("🔐 SESSION_STATE[proactive_init_start]: userId=\(userId.prefix(8))...", category: "SessionInit")

        let staleSPKMaxRetries = 2
        let staleSPKRetryDelay: UInt64 = 60 // seconds

        var lastError: Error?
        for attempt in 0...staleSPKMaxRetries {
            if attempt > 0 {
                Log.info("🔁 SESSION_STATE[stale_spk_retry_\(attempt)]: waiting \(staleSPKRetryDelay)s for peer SPK rotation to propagate — userId=\(userId.prefix(8))…", category: "SessionInit")
                try? await Task.sleep(nanoseconds: staleSPKRetryDelay * 1_000_000_000)
                guard !Task.isCancelled else { break }
            }

            do {
                let bundle = try await fetchPublicKeyWithRetry(userId: userId)
                try initializeSession(userId: userId, bundle: bundle, deleteExisting: true)

                Log.info("✅ SESSION_STATE[proactive_init_success]: userId=\(userId.prefix(8))...", category: "SessionInit")
                await MainActor.run { onSuccess() }
                return
            } catch SessionError.peerSPKStale(let days) where attempt < staleSPKMaxRetries {
                // Peer just came online and rotated — server may not have updated yet.
                // We'll retry after a delay.
                Log.error("⚠️ Peer SPK stale for \(userId.prefix(8))… (\(String(format: "%.1f", days))d) — will retry in \(staleSPKRetryDelay)s (\(attempt + 1)/\(staleSPKMaxRetries))", category: "SessionInit")
                lastError = SessionError.peerSPKStale(ageDays: days)
                continue
            } catch {
                lastError = error
                break
            }
        }

        let finalError = lastError ?? NetworkError.connectionFailed
        Log.error("❌ SESSION_STATE[proactive_init_failed]: userId=\(userId.prefix(8))..., error=\(finalError.localizedDescription)", category: "SessionInit")
        await MainActor.run { onFailure(finalError) }
    }
}
