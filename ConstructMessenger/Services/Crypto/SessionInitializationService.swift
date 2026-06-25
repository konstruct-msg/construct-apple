import Foundation
import os.log

/// Errors specific to the session-init layer (distinct from CryptoManagerError).
enum SessionError: Error, LocalizedError, ApplicationLayerError {
    /// Server returned a bundle whose SPK rotation epoch is older than the last
    /// seen epoch for this contact — possible replay attack.
    case staleSPKBundle(epoch: UInt32, knownEpoch: UInt32)
    /// Peer's SPK is older than the Rust core's staleness limit.
    /// The peer must open their app to trigger SPK rotation before a session can be established.
    case peerSPKStale(ageDays: Double)
    /// Peer is a PQ device but their bundle has `kyberSpkRotationEpoch == 0`,
    /// meaning they never uploaded a Kyber SPK. Session init must be refused to
    /// avoid silently downgrading to classical-only key agreement.
    case kyberEpochRequired

    var errorDescription: String? {
        switch self {
        case .staleSPKBundle(let epoch, let knownEpoch):
            return "SPK bundle replay: received epoch \(epoch) ≤ known epoch \(knownEpoch)"
        case .peerSPKStale(let days):
            return "Contact's encryption keys are \(String(format: "%.0f", days)) days old and need to be refreshed — ask them to open the app"
        case .kyberEpochRequired:
            return "Contact's post-quantum keys are incomplete — ask them to update the app"
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
                Log.info("SESSION_STATE[fetch_bundle_attempt_\(attempt)]: userId=\(userId.prefix(8))..., deviceId=\(deviceId?.prefix(8) ?? "nil")...", category: "SessionInit")
                let keyBundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId, deviceId: deviceId)
                Log.info("SESSION_STATE[fetch_bundle_success]: userId=\(userId.prefix(8))..., hasVerifyingKey=\(!keyBundle.verifyingKey.isEmpty)", category: "SessionInit")
                return keyBundle
            } catch {
                lastError = error
                Log.error("SESSION_STATE[fetch_bundle_failed]: attempt=\(attempt)/\(maxAttempts), error=\(error) (\(type(of: error)))", category: "SessionInit")
                
                if attempt < maxAttempts {
                    Log.info("Retrying public key fetch in \(delay)s...", category: "SessionInit")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= 2  // Exponential backoff: 1s, 2s, 4s
                }
            }
        }
        
        Log.error("SESSION_STATE[fetch_bundle_exhausted]: userId=\(userId.prefix(8))..., allAttemptsFailed", category: "SessionInit")
        throw lastError ?? NetworkError.connectionFailed
    }
    
    /// Initialize a session with a recipient using their public key bundle
    func initializeSession(
        userId: String,
        bundle: PublicKeyBundleData,
        deleteExisting: Bool = true,
        allowStale: Bool = false
    ) throws -> Void {
        // Proactively delete stale session if requested
        if deleteExisting {
            if CryptoManager.shared.hasSession(for: userId) {
                CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
                Log.info("Proactively deleted any existing session for \(userId) before initialization.", category: "SessionInit")
            }
        }

        // Epoch replay-attack check: reject bundles where the server's monotonic
        // rotation counter has not advanced beyond what we last saw for this contact.
        // (Skip when epoch == 0, which means the server hasn't migrated yet.)
        if bundle.spkRotationEpoch > 0 {
            let knownEpoch = KeychainManager.shared.loadSpkEpoch(for: userId)
            if bundle.spkRotationEpoch < knownEpoch {
                Log.error("SESSION_STATE[spk_replay_rejected]: epoch=\(bundle.spkRotationEpoch) < known=\(knownEpoch) for \(userId.prefix(8))… — possible SPK replay attack", category: "SessionInit")
                throw SessionError.staleSPKBundle(epoch: bundle.spkRotationEpoch, knownEpoch: knownEpoch)
            }
            KeychainManager.shared.saveSpkEpoch(bundle.spkRotationEpoch, for: userId)
        }

        // PQ_HYBRID bundles (suiteId == 2) must have a non-zero Kyber SPK epoch.
        // epoch == 0 means the peer never uploaded a Kyber SPK; refuse to proceed
        // rather than silently falling back to classical-only key agreement.
        if bundle.suiteId == 2 && bundle.kyberSpkRotationEpoch == 0 {
            Log.error("SESSION_STATE[kyber_epoch_missing]: suiteId=2 but kyberSpkRotationEpoch==0 for \(userId.prefix(8))… — refusing PQ session init", category: "SessionInit")
            throw SessionError.kyberEpochRequired
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
                kyberSpkRotationEpoch: bundle.kyberSpkRotationEpoch,
                allowStale: allowStale
            )
            PerformanceMetrics.shared.end(.sessionInitStart, endEvent: .sessionInitEnd, label: String(userId.prefix(8)))
            // Track at-risk state: a degraded (stale-SPK) init is authentic but should be
            // re-keyed once the peer rotates; a clean init clears any prior at-risk flag.
            if allowStale {
                KeychainManager.shared.saveSessionAtRiskFlag(for: userId)
                Log.info("Session initialized as INITIATOR (degraded/at-risk) for \(userId)", category: "SessionInit")
            } else {
                KeychainManager.shared.deleteSessionAtRiskFlag(for: userId)
                Log.info("Session initialized as INITIATOR for \(userId)", category: "SessionInit")
            }
        } catch let sessionError as SessionError {
            throw sessionError
        } catch {
            Log.error("Session init failed for \(userId): \(error)", category: "SessionInit")
            Log.error("   bundle.suiteId=\(bundle.suiteId), identityPublic.len=\(bundle.identityPublic.count), signedPrekeyPublic.len=\(bundle.signedPrekeyPublic.count)", category: "SessionInit")
            throw error
        }
    }
    
    /// Proactively initialize session for a user (fetch bundle + initialize).
    ///
    /// When the peer's SPK is stale (`peerSPKStale`), the peer may have just come
    /// online and rotated their keys. The server may not yet reflect the new
    /// `spk_uploaded_at`. In that case we wait `staleSPKRetryDelay` seconds and retry
    /// up to `staleSPKMaxRetries` times.
    ///
    /// **Degrade path**: if `ageDays >= staleSPKFastFailDays` (30.25d = 6h past the Rust 30-day
    /// limit), the peer has clearly not been online recently — waiting is pointless, so we go
    /// straight to a degraded (at-risk) init instead of burning 2 × 60 s on retries.
    func initializeSessionProactively(
        userId: String,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) async {
        Log.info("SESSION_STATE[proactive_init_start]: userId=\(userId.prefix(8))...", category: "SessionInit")

        let staleSPKMaxRetries = 2
        let staleSPKRetryDelay: UInt64 = 60 // seconds
        /// Grace window above the Rust 30-day staleness limit. If the SPK is only ≤ 6 h past
        /// the limit the peer may have just come online and rotated; the server bundle
        /// cache may simply not have propagated yet. Beyond this window the peer has been
        /// offline for a long time and no amount of waiting will help — degrade instead.
        let staleSPKFastFailDays: Double = 30.25

        var lastError: Error?
        for attempt in 0...staleSPKMaxRetries {
            if attempt > 0 {
                Log.info("SESSION_STATE[stale_spk_retry_\(attempt)]: waiting \(staleSPKRetryDelay)s for peer SPK rotation to propagate — userId=\(userId.prefix(8))…", category: "SessionInit")
                try? await Task.sleep(nanoseconds: staleSPKRetryDelay * 1_000_000_000)
                guard !Task.isCancelled else { break }
            }

            do {
                let bundle = try await fetchPublicKeyWithRetry(userId: userId)
                try initializeSession(userId: userId, bundle: bundle, deleteExisting: true)

                Log.info("SESSION_STATE[proactive_init_success]: userId=\(userId.prefix(8))...", category: "SessionInit")
                await MainActor.run { onSuccess() }
                return
            } catch SessionError.peerSPKStale(let days) where attempt < staleSPKMaxRetries && days < staleSPKFastFailDays {
                // SPK is barely past the staleness limit — peer may have just come online
                // and rotated. Wait for server bundle cache to propagate.
                Log.error("Peer SPK stale for \(userId.prefix(8))… (\(String(format: "%.1f", days))d) — will retry in \(staleSPKRetryDelay)s (\(attempt + 1)/\(staleSPKMaxRetries))", category: "SessionInit")
                lastError = SessionError.peerSPKStale(ageDays: days)
                continue
            } catch SessionError.peerSPKStale(let days) {
                // SPK is well past the staleness limit — peer has been offline for a long
                // time and won't rotate by waiting. Rather than dead-ending, fall back to a
                // DEGRADED init so the message can still be established + queued. The session
                // is flagged at-risk; if the peer rotated and dropped the old SPK private key,
                // the first message fails to decrypt and the existing healing path repairs it.
                // See the stale-peer-reachability decision record.
                Log.error("SESSION_STATE[stale_spk_degraded_init]: peer \(userId.prefix(8))… SPK is \(String(format: "%.1f", days))d old (≥\(staleSPKFastFailDays)d) — initiating degraded (at-risk) session", category: "SessionInit")
                do {
                    let bundle = try await fetchPublicKeyWithRetry(userId: userId)
                    try initializeSession(userId: userId, bundle: bundle, deleteExisting: true, allowStale: true)
                    Log.info("SESSION_STATE[proactive_init_success_degraded]: userId=\(userId.prefix(8))…", category: "SessionInit")
                    await MainActor.run { onSuccess() }
                    return
                } catch {
                    Log.error("SESSION_STATE[degraded_init_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                    lastError = error
                    break
                }
            } catch {
                lastError = error
                break
            }
        }

        let finalError = lastError ?? NetworkError.connectionFailed
        Log.error("SESSION_STATE[proactive_init_failed]: userId=\(userId.prefix(8))..., error=\(finalError.localizedDescription)", category: "SessionInit")
        await MainActor.run { onFailure(finalError) }
    }

    // MARK: - At-risk session auto-upgrade (Phase 2)

    /// SPK age below which we consider a peer to have come back online and rotated, so an at-risk
    /// (degraded) session can be safely re-keyed to a fresh one. A peer who came back online
    /// force-rotates (8-day client threshold), so a genuinely-returned peer is well under this.
    /// Comfortably under the Rust 30-day strict limit so the subsequent strict `initializeSession`
    /// cannot itself throw `peerSPKStale`.
    private let atRiskUpgradeFreshnessDays: Double = 9.0
    /// Minimum spacing between upgrade attempts per contact, so a peer who is still offline doesn't
    /// trigger a bundle fetch on every chat open.
    private let atRiskUpgradeCooldown: TimeInterval = 3600 // 1 hour
    private static let atRiskUpgradeAttemptPrefix = "session.atRiskUpgrade.lastAttempt."

    /// If the session with `userId` was established via a degraded (stale-SPK) init AND the peer has
    /// since rotated their SPK (now fresh), re-key cleanly to a fresh session and clear the at-risk
    /// flag — restoring full forward secrecy. No-op if the session isn't at-risk, the peer is still
    /// stale (keeps the working degraded session — no churn), or we attempted recently. See the
    /// `stale-peer-reachability` decision record (Phase 2).
    func upgradeAtRiskSessionIfPeerFresh(userId: String) async {
        guard KeychainManager.shared.loadSessionAtRiskFlag(for: userId) else { return }
        guard CryptoManager.shared.hasSession(for: userId) else { return }

        // Rate-limit per contact.
        let attemptKey = Self.atRiskUpgradeAttemptPrefix + userId
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: attemptKey)
        if last > 0, now - last < atRiskUpgradeCooldown { return }
        UserDefaults.standard.set(now, forKey: attemptKey)

        do {
            let bundle = try await fetchPublicKeyWithRetry(userId: userId)
            // spk_uploaded_at == 0 means a legacy server that doesn't report freshness — we can't
            // tell if the peer rotated, so leave the degraded session in place.
            guard bundle.spkUploadedAt > 0 else { return }
            let ageDays = (now - Double(bundle.spkUploadedAt)) / 86400.0
            guard ageDays < atRiskUpgradeFreshnessDays else {
                Log.info("SESSION_STATE[at_risk_upgrade_skip]: peer \(userId.prefix(8))… SPK still \(String(format: "%.1f", ageDays))d old — keeping degraded session", category: "SessionInit")
                return
            }

            // Peer is fresh again → clean strict re-init. On success, initializeSession clears the
            // at-risk flag (deleteSessionAtRiskFlag in the non-degraded branch).
            try initializeSession(userId: userId, bundle: bundle, deleteExisting: true)
            Log.info("SESSION_STATE[at_risk_upgraded]: re-keyed to fresh session for \(userId.prefix(8))…", category: "SessionInit")
            await MainActor.run {
                NotificationCenter.default.post(name: .sessionAtRiskChanged, object: nil, userInfo: ["userId": userId])
            }
        } catch {
            Log.info("SESSION_STATE[at_risk_upgrade_failed]: \(error.localizedDescription) for \(userId.prefix(8))… — will retry later", category: "SessionInit")
        }
    }
}
