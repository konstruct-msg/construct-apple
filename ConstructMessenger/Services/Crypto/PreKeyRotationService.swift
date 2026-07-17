//
//  PreKeyRotationService.swift
//  Construct Messenger
//
//  Atomic rotation of the classical (X25519) and Kyber signed pre-keys.
//
//  Both keys are rotated in a single RotateSignedPreKeyRequest RPC so the server
//  updates them transactionally, preventing desynchronization where one key
//  is replaced on the server but the other is not.
//
//  Rotation schedule: 7 days by default.
//  Called from ChatsViewModel on app launch after authentication.
//

import Foundation

/// Manages scheduled and on-demand atomic rotation of signed pre-keys.
final class PreKeyRotationService {
    static let shared = PreKeyRotationService()
    private init() {}

    // MARK: - Constants

    private static let lastRotationKey    = "construct.spk.lastRotationTimestamp"
    /// Tracks when the SPK was first uploaded (set at registration AND updated on each rotation).
    /// Used to detect SPK age independently from the rotation timer, so we can force-rotate
    /// before the Rust core's staleness limit rejects the bundle on the peer side.
    private static let spkUploadKey       = "construct.spk.uploadTimestamp"
    /// Weekly rotation. We rotate the client's OWN SPK far more aggressively (7 days) than the
    /// peer-side staleness limit (`SPK_MAX_AGE_SECS`, now 30 days) requires — this is forward-secrecy
    /// hygiene for our own outbound sessions, independent of how tolerant peers are of stale bundles.
    private static let rotationIntervalDays: Double = 7
    /// Force rotation when the SPK age crosses this, even if the timer hasn't fired. Kept tight
    /// (8 days, ~weekly) for FS hygiene; comfortably below the 30-day peer staleness limit.
    private static let spkMaxAgeDays: Double = 8
    /// Minimum interval between retry attempts when the stream was down during a previous try.
    /// Prevents hammering the server during rapid reconnect cycling.
    private static let retryIntervalSeconds: TimeInterval = 120

    // MARK: - Retry State

    /// True when a rotation was attempted but failed due to a transient stream error.
    /// Cleared on success or when rotation is no longer due.
    /// Used by ChatsViewModel to schedule a retry when the stream reconnects.
    private(set) var hasPendingRetry = false
    /// Prevents concurrent rotation attempts (e.g. three startup callers firing in parallel).
    private var isRotating = false
    /// Timestamp of the last rotation attempt (success or failure). Used to throttle retries.
    private var lastAttemptAt: TimeInterval = 0

    // MARK: - Public API

    /// Check whether SPK rotation is due and perform it if so.
    ///
    /// Call on every app launch after the user is authenticated and a gRPC
    /// channel is available. No-op if the last rotation was < 7 days ago
    /// AND the SPK is < 12 days old.
    ///
    /// Safe to call concurrently — the `isRotating` flag serialises attempts.
    /// When a previous attempt failed (stream was down), `hasPendingRetry` is set
    /// and the next call will retry, subject to a 120s throttle.
    func rotateIfNeeded(deviceId: String) async {
        guard !deviceId.isEmpty else {
            Log.error("SPK rotation skipped — deviceId is empty (Keychain unavailable?)", category: "SPKRotation")
            return
        }
        guard !isRotating else {
            Log.debug("SPK rotation already in progress — skipping duplicate call", category: "SPKRotation")
            return
        }
        guard isRotationDue() else {
            hasPendingRetry = false
            Log.debug("SPK rotation not due yet", category: "SPKRotation")
            return
        }
        // Throttle retries: if the previous attempt failed (stream was down), wait at
        // least retryIntervalSeconds before trying again. This prevents hammering the
        // server during rapid ICE reconnect cycling (dozens of attempts per minute).
        let now = Date().timeIntervalSince1970
        if hasPendingRetry && now - lastAttemptAt < Self.retryIntervalSeconds {
            Log.debug("SPK rotation retry throttled (\(Int(Self.retryIntervalSeconds - (now - lastAttemptAt)))s remaining)", category: "SPKRotation")
            return
        }
        isRotating = true
        lastAttemptAt = now
        defer { isRotating = false }
        Log.info("SPK rotation due — starting atomic rotation", category: "SPKRotation")
        do {
            try await performAtomicRotation(deviceId: deviceId, reason: .scheduled)
            hasPendingRetry = false
        } catch {
            hasPendingRetry = true
            Log.error("SPK rotation failed: \(error)", category: "SPKRotation")
        }
    }

    /// Force rotation regardless of schedule (e.g., triggered by security event).
    func forceRotate(deviceId: String, reason: Shared_Proto_Services_V1_SignedPreKeyRotationReason) async throws {
        Log.info("Force SPK rotation requested (reason: \(reason))", category: "SPKRotation")
        try await performAtomicRotation(deviceId: deviceId, reason: reason)
    }

    /// Convenience overload — reads deviceId from Keychain.
    /// Use from diagnostic UI where callers don't have direct access to deviceId.
    func forceRotate() async {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        guard !deviceId.isEmpty else {
            Log.error("forceRotate: deviceId not available", category: "SPKRotation")
            return
        }
        do {
            try await forceRotate(deviceId: deviceId, reason: .user)
            Log.info("Force SPK rotation complete", category: "SPKRotation")
        } catch {
            Log.error("Force SPK rotation failed: \(error)", category: "SPKRotation")
        }
    }

    // MARK: - Core Rotation Logic

    /// Atomically rotate both SPKs:
    ///  1. Rust core generates new X25519 SPK (in-core — old key kept for grace period)
    ///  2. PQCKeyManager generates new Kyber SPK in memory (NOT yet in Keychain)
    ///  3. Both uploaded in ONE RotateSignedPreKeyRequest RPC
    ///  4. On server success → commit Kyber SPK to Keychain
    ///  5. Persist Rust core state and update last-rotation timestamp
    ///
    ///  On ANY failure after Phase 1, the Rust core is reloaded from Keychain to
    ///  roll back the in-memory SPK mutation and prevent AEAD decryption failures
    ///  caused by a desync between the in-memory state and what the server serves.
    private func performAtomicRotation(
        deviceId: String,
        reason: Shared_Proto_Services_V1_SignedPreKeyRotationReason,
        allowHybridSPKSignature: Bool = true
    ) async throws {
        guard CryptoManager.shared.orchestratorCore != nil else {
            throw PreKeyRotationError.cryptoCoreNotInitialized
        }

        // ── Phase 1: generate both keys ──────────────────────────────────────

        // Classic SPK: Rust core rotates internally (serialized via coreLock).
        // NOTE: rotateSignedPrekey() mutates the Rust core in memory immediately.
        // If Phase 2 (RPC) fails, we MUST reload from Keychain to roll back.
        let rotatedSpk = try CryptoManager.shared.rotateSignedPrekey()
        let classicPubData = Data(rotatedSpk.publicKey)
        let classicSigData = Data(rotatedSpk.signature)
        let classicKey = (keyId: rotatedSpk.keyId, publicKey: classicPubData, signature: classicSigData)

        // Kyber SPK: generated in memory only — NOT committed yet
        let kyberInMemory: (publicKey: Data, secretKey: Data, keyId: UInt32)
        let kyberKey: (keyId: UInt32, publicKey: Data, signature: Data)
        do {
            kyberInMemory = try PQCKeyManager.shared.generateKyberSPKInMemory()
            let kyberSig = try PQCKeyManager.signKyberKey(publicKey: kyberInMemory.publicKey)
            kyberKey = (keyId: kyberInMemory.keyId, publicKey: kyberInMemory.publicKey, signature: kyberSig)
        } catch {
            CryptoManager.shared.reloadCoreFromKeychain()
            throw error
        }

        Log.info("SPK rotation: classic keyId=\(classicKey.keyId) kyber keyId=\(kyberKey.keyId)", category: "SPKRotation")

        // Hybrid (ML-DSA) signatures over the NEW keys, sent with the rotation so the server
        // stores them ATOMICALLY — closing the window where a rotated-but-unsigned SPK makes peers
        // reject the bundle ("SPK hybrid signature missing"). Only when the hybrid identity is
        // already published (else the server has no hybrid identity key to verify against, and the
        // rotation would fail): in that case fall back to the post-rotation publish below. `try?`
        // so a signing hiccup degrades to the old publish path rather than failing rotation.
        // `allowHybridSPKSignature == false` is the deadlock-breaker retry: rotate classic-only so
        // the server verifies just the classic SPK signature (against our intact device identity)
        // and re-syncs the SPK, then the post-rotation publish re-attaches the hybrid signature.
        // Evaluate the await separately: it cannot live inside the `&&` autoclosure.
        let hybridPublished = await HybridIdentityService.isHybridIdentityPublished
        let canSignHybrid = allowHybridSPKSignature && hybridPublished
        // Use the core-routed prekey hybrid signer (message format centralized in core).
        let spkHybridSig = canSignHybrid ? (try? CryptoManager.shared.signHybridPrekey(suiteId: 0x01, publicKey: classicPubData)) : nil
        let kyberHybridSig = canSignHybrid ? (try? CryptoManager.shared.signHybridPrekey(suiteId: 0x10, publicKey: kyberInMemory.publicKey)) : nil
        let atomicHybridSent = spkHybridSig != nil && kyberHybridSig != nil

        // ── Phase 2: single atomic RPC ───────────────────────────────────────

        let response: Shared_Proto_Services_V1_RotateSignedPreKeyResponse
        do {
            response = try await KeyServiceClient.shared.rotateSignedPreKey(
                deviceId: deviceId,
                newClassicKey: classicKey,
                newKyberKey: kyberKey,
                reason: reason,
                signedPreKeyHybridSignature: spkHybridSig,
                kyberSignedPreKeyHybridSignature: kyberHybridSig
            )
        } catch {
            // RPC failed — roll back the in-memory Rust core to Keychain state.
            // Without this, the core has a new SPK that the server doesn't know
            // about, causing AEAD failures for all incoming session initiations.
            Log.error("SPK rotation RPC failed — rolling back Rust core: \(error)", category: "SPKRotation")
            CryptoManager.shared.reloadCoreFromKeychain()

            // Deadlock-breaker: the server rejected the OPTIONAL hybrid SPK signature — it verifies
            // that over its own stored SPK, which mismatches ours when the SPK is desynced (e.g. a
            // prior rotation RPC failed). That mismatch also blocks the hybrid identity publish,
            // which SPK rotation's hybrid check depends on — a cycle that never self-heals. The
            // classic SPK signature needs no hybrid key and verifies against our (intact) device
            // identity, so retry the rotation classic-only to re-sync the SPK; the post-rotation
            // publish then re-attaches the hybrid signature over the now-synced SPK. Retry once.
            // See otpk-session-init-deadlock (SPK↔hybrid deadlock).
            if allowHybridSPKSignature && atomicHybridSent && Self.isHybridSPKSignatureRejection(error) {
                Log.info("SPK rotation: hybrid SPK signature rejected by server — retrying classic-only to break the SPK↔hybrid deadlock", category: "SPKRotation")
                try await performAtomicRotation(deviceId: deviceId, reason: reason, allowHybridSPKSignature: false)
                return
            }
            throw error
        }

        // ── Phase 3: commit on success ───────────────────────────────────────

        // Only write Kyber to Keychain AFTER the server confirmed the rotation.
        // Classic SPK is already updated inside the Rust core; we persist its state.
        try PQCKeyManager.shared.commitKyberSPK(
            publicKey: kyberInMemory.publicKey,
            secretKey: kyberInMemory.secretKey,
            keyId: kyberInMemory.keyId
        )
        let persisted = CryptoManager.shared.persistCoreState()
        if !persisted {
            // CRITICAL: server has the NEW SPK but Keychain still has the OLD one.
            // On next app restart the core will load the old SPK private key while
            // the server serves the new SPK public key → permanent AEAD failures.
            // Reload the core from Keychain so the in-memory state matches Keychain,
            // then re-upload the old SPK to bring the server back in sync.
            Log.error("SPK rotation: Keychain persist FAILED — rolling back server SPK", category: "SPKRotation")
            CryptoManager.shared.reloadCoreFromKeychain()
            throw PreKeyRotationError.keychainPersistFailed
        }

        recordRotation()
        let serverKyberKeyId = response.hasNewKyberKeyID ? response.newKyberKeyID : kyberKey.keyId
        Log.info("SPK rotation complete: classic keyId=\(classicKey.keyId) (server: \(response.newKeyID)), kyber keyId=\(serverKyberKeyId)", category: "SPKRotation")

        if atomicHybridSent {
            // Hybrid signatures were stored atomically with the rotation — no separate publish
            // needed and no window. Record the new SPK fingerprint so launch publishIfNeeded
            // doesn't redundantly re-publish.
            await HybridIdentityService.recordHybridPublished(spkPublic: classicPubData)
            Log.info("SPK rotation: hybrid signatures stored atomically with rotation", category: "SPKRotation")
        } else {
            // Fallback (hybrid identity not yet published, or signing failed): re-attach the hybrid
            // signatures over the freshly-rotated keys via a separate publish. Bounded retry; if it
            // still fails, HybridIdentityService.publishIfNeeded() repairs it on the next launch
            // (it detects the now-stale SPK fingerprint and re-publishes).
            for attempt in 1...3 {
                do {
                    try await HybridIdentityService.publish(deviceId: deviceId)
                    break
                } catch {
                    Log.error("SPK rotation: hybrid signature re-attach failed (attempt \(attempt)/3, non-fatal): \(error.localizedDescription)", category: "SPKRotation")
                    if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                }
            }
        }
    }

    /// True when a rotation RPC failed specifically because the server could not verify the
    /// (optional) hybrid SPK signature — the SPK↔hybrid deadlock signal. Matched on the server
    /// message text ("SPK hybrid signature verification failed"), which reaches us in the RPCError.
    /// Deliberately narrow: any other failure keeps the original rollback-and-throw behaviour.
    private static func isHybridSPKSignatureRejection(_ error: Error) -> Bool {
        // Match on the server's message text, carried in the transport error's description.
        // `String(describing:)` avoids a hard dependency on GRPCCore's RPCError type here and
        // works whether the thrown error is an RPCError or a wrapper around one.
        String(describing: error).contains("SPK hybrid signature verification failed")
    }

    // MARK: - Schedule Helpers

    private func isRotationDue() -> Bool {
        let now = Date().timeIntervalSince1970

        // 1. Timer-based check: rotate every 7 days
        let last = UserDefaults.standard.double(forKey: Self.lastRotationKey)
        if last <= 0 { return true }  // Never rotated
        let daysSinceRotation = (now - last) / 86400
        if daysSinceRotation >= Self.rotationIntervalDays { return true }

        // 2. Age-based check: force-rotate if SPK is approaching the Rust staleness limit.
        // This catches cases where the timer was reset (app reinstall, UserDefaults cleared)
        // but the server's SPK was uploaded long ago and would soon be rejected by peers.
        let uploadedAt = UserDefaults.standard.double(forKey: Self.spkUploadKey)
        if uploadedAt > 0 {
            let spkAgeDays = (now - uploadedAt) / 86400
            if spkAgeDays >= Self.spkMaxAgeDays {
                Log.info("SPK age \(String(format: "%.1f", spkAgeDays))d ≥ \(Self.spkMaxAgeDays)d limit — forcing rotation", category: "SPKRotation")
                return true
            }
        }

        return false
    }

    /// Call when an SPK is first uploaded (registration only — NOT recovery/device link).
    /// Recovery must use forceRotate() instead to upload a fresh key.
    ///
    /// Sets BOTH the upload timestamp AND the last-rotation timestamp to `now`.
    /// Without this, `isRotationDue()` sees `lastRotationKey == 0` (never rotated)
    /// and fires SPK rotation immediately after every fresh registration.
    func recordSpkUpload() {
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: Self.spkUploadKey)
        UserDefaults.standard.set(now, forKey: Self.lastRotationKey)
        Log.debug("SPK upload timestamp recorded", category: "SPKRotation")
    }

    /// Sync the local SPK upload timestamp with the value the server reports.
    /// Call this whenever a bundle fetch returns our own SPK metadata.
    /// If the server timestamp is older than the local one, the local record was
    /// set incorrectly (e.g. from recovery without a real SPK upload) and we
    /// overwrite it so the age-based rotation check fires correctly.
    func syncSpkUploadTimestamp(serverUploadedAt: TimeInterval) {
        guard serverUploadedAt > 0 else { return }
        let local = UserDefaults.standard.double(forKey: Self.spkUploadKey)
        // Local says "newer" than server — this is the staleness bug: local was set
        // to Date.now during recovery while the server still has the old key.
        if local <= 0 || serverUploadedAt < local {
            UserDefaults.standard.set(serverUploadedAt, forKey: Self.spkUploadKey)
            Log.info("SPK upload timestamp synced from server: \(Int(serverUploadedAt)) (was \(Int(local)))", category: "SPKRotation")
        }
    }

    private func recordRotation() {
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: Self.lastRotationKey)
        UserDefaults.standard.set(now, forKey: Self.spkUploadKey)
    }

    // MARK: - Server consistency

    /// Compare local public keys with what the server serves.
    /// Returns `true` if keys match, `false` if a desync was detected (and repaired if possible).
    @discardableResult
    func verifyAndRepairKeyConsistency() async -> Bool {
        guard let localUserId = await AuthSessionManager.shared.currentUserId, !localUserId.isEmpty else {
            Log.error("Key consistency check skipped — userId unavailable", category: "SPKRotation")
            return true
        }
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        do {
            let (localIk, localSpk) = try CryptoManager.shared.localBundlePublicKeys()
            // Fetch THIS device's bundle. Without the deviceId the server may return a *different*
            // device's bundle on a multi-device account (whichever it picks for the user), producing
            // a spurious identity "desync" against our local keys — and, worse, a destructive repair
            // rotation. Pin the query to our own deviceId so the comparison is apples-to-apples.
            let serverBundle = try await KeyServiceClient.shared.getPreKeyBundle(
                userId: localUserId,
                deviceId: deviceId.isEmpty ? nil : deviceId
            )

            let ikMatch  = localIk  == serverBundle.identityPublic
            let spkMatch = localSpk == serverBundle.signedPrekeyPublic

            // Kyber SPK — the PQXDH KEM leg. The X25519 checks above do NOT cover it: the hybrid
            // suite's KEM is X25519-only and the ML-KEM contribution is a SEPARATE layer. A Kyber
            // SPK desync (our local Kyber SPK private ≠ the Kyber SPK public the server serves)
            // leaves identity/SPK matching yet makes EVERY PQXDH handshake AEAD-fail on the
            // responder (the KEM secret diverges), with no visible desync — the build-497 blocker.
            // Compare it too; "both absent" counts as matching (Ed25519-only / no PQ peer).
            let localKyber = try? PQCKeyManager.shared.kyberSPKPublic()
            let serverKyber = serverBundle.kyberPreKeyPublic
            let kyberMatch: Bool = {
                guard let localKyber, !localKyber.isEmpty else { return serverKyber?.isEmpty ?? true }
                return localKyber == serverKyber
            }()

            if ikMatch && spkMatch && kyberMatch {
                Log.info("Key consistency: identity, SPK and Kyber SPK match server", category: "SPKRotation")
                return true
            }

            func hexPrefix(_ d: Data) -> String { d.prefix(8).map { String(format: "%02x", $0) }.joined() }

            if !ikMatch {
                Log.error("KEY DESYNC: identity_public LOCAL=\(hexPrefix(localIk))… SERVER=\(hexPrefix(serverBundle.identityPublic))…", category: "SPKRotation")
            }
            if !spkMatch {
                Log.error("KEY DESYNC: signed_prekey LOCAL=\(hexPrefix(localSpk))… SERVER=\(hexPrefix(serverBundle.signedPrekeyPublic))…", category: "SPKRotation")
            }
            if !kyberMatch {
                Log.error("KEY DESYNC: kyber_signed_prekey LOCAL=\(hexPrefix(localKyber ?? Data()))… SERVER=\(hexPrefix(serverKyber ?? Data()))…", category: "SPKRotation")
            }

            // Repair via atomic rotation — it rotates the classic AND Kyber SPK together, so it
            // heals either SPK/Kyber desync. An identity mismatch is NOT rotation-repairable
            // (rotation only re-signs the SPK against the identity the server already holds for us);
            // rotating when the server has a *different* identity for this device is futile and —
            // before the hybrid identity is published — fails the RPC with "device has no hybrid
            // identity key". So only repair when the identity itself matches.
            if ikMatch, !spkMatch || !kyberMatch, !deviceId.isEmpty {
                Log.info("Key consistency: attempting SPK+Kyber re-upload to repair desync…", category: "SPKRotation")
                try await forceRotate(deviceId: deviceId, reason: .security)
                Log.info("Key consistency: SPK+Kyber re-upload complete", category: "SPKRotation")
            }
            return false
        } catch {
            Log.error("Key consistency check failed: \(error)", category: "SPKRotation")
            return true
        }
    }
}

// MARK: - Errors

enum PreKeyRotationError: Error, LocalizedError {
    case cryptoCoreNotInitialized
    case invalidKeyMaterial
    case keychainCommitFailed
    case keychainPersistFailed

    var errorDescription: String? {
        switch self {
        case .cryptoCoreNotInitialized: return "Crypto core not initialized"
        case .invalidKeyMaterial:       return "Invalid rotated SPK key material from Rust core"
        case .keychainCommitFailed:     return "Failed to commit rotated Kyber SPK to Keychain"
        case .keychainPersistFailed:    return "Failed to persist Rust core state to Keychain after SPK rotation"
        }
    }
}
