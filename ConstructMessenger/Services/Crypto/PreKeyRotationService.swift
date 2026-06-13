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
    /// Must be strictly less than SPK_MAX_AGE_SECS in the Rust core (currently 10 days).
    /// 7 days = weekly rotation; gives a full rotation-period grace buffer before
    /// the Rust peer-side check rejects the bundle as stale.
    private static let rotationIntervalDays: Double = 7
    /// Force rotation when the actual SPK age approaches the Rust staleness limit.
    /// 8 days = 2-day safety margin before the Rust 10-day hard rejection.
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
        reason: Shared_Proto_Services_V1_SignedPreKeyRotationReason
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

        // ── Phase 2: single atomic RPC ───────────────────────────────────────

        let response: Shared_Proto_Services_V1_RotateSignedPreKeyResponse
        do {
            response = try await KeyServiceClient.shared.rotateSignedPreKey(
                deviceId: deviceId,
                newClassicKey: classicKey,
                newKyberKey: kyberKey,
                reason: reason
            )
        } catch {
            // RPC failed — roll back the in-memory Rust core to Keychain state.
            // Without this, the core has a new SPK that the server doesn't know
            // about, causing AEAD failures for all incoming session initiations.
            Log.error("SPK rotation RPC failed — rolling back Rust core: \(error)", category: "SPKRotation")
            CryptoManager.shared.reloadCoreFromKeychain()
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

        // Rotation clears the hybrid prekey signatures server-side; re-attach them over
        // the freshly-rotated SPK / Kyber SPK. Bounded retry to ride out a transient RPC
        // failure (which previously left the bundle with a hybrid identity but no SPK
        // hybrid signature → peers reject it with "SPK hybrid signature missing"). If it
        // still fails, HybridIdentityService.publishIfNeeded() repairs it on the next
        // launch: it detects the now-stale SPK fingerprint and re-publishes.
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
        do {
            let (localIk, localSpk) = try CryptoManager.shared.localBundlePublicKeys()
            let serverBundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: localUserId)

            let ikMatch  = localIk  == serverBundle.identityPublic
            let spkMatch = localSpk == serverBundle.signedPrekeyPublic

            if ikMatch && spkMatch {
                Log.info("Key consistency: identity and SPK match server", category: "SPKRotation")
                return true
            }

            func hexPrefix(_ d: Data) -> String { d.prefix(8).map { String(format: "%02x", $0) }.joined() }

            if !ikMatch {
                Log.error("KEY DESYNC: identity_public LOCAL=\(hexPrefix(localIk))… SERVER=\(hexPrefix(serverBundle.identityPublic))…", category: "SPKRotation")
            }
            if !spkMatch {
                Log.error("KEY DESYNC: signed_prekey LOCAL=\(hexPrefix(localSpk))… SERVER=\(hexPrefix(serverBundle.signedPrekeyPublic))…", category: "SPKRotation")
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                if !deviceId.isEmpty {
                    Log.info("Key consistency: attempting SPK re-upload to repair desync…", category: "SPKRotation")
                    try await forceRotate(deviceId: deviceId, reason: .security)
                    Log.info("Key consistency: SPK re-upload complete", category: "SPKRotation")
                }
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
