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
//  Rotation schedule: monthly (30 days) by default.
//  Called from ChatsViewModel on app launch after authentication.
//

import Foundation

/// Manages scheduled and on-demand atomic rotation of signed pre-keys.
final class PreKeyRotationService {
    static let shared = PreKeyRotationService()
    private init() {}

    // MARK: - Constants

    private static let lastRotationKey = "construct.spk.lastRotationTimestamp"
    private static let rotationIntervalDays: Double = 30

    // MARK: - Public API

    /// Check whether SPK rotation is due and perform it if so.
    ///
    /// Call on every app launch after the user is authenticated and a gRPC
    /// channel is available. No-op if the last rotation was < 30 days ago.
    func rotateIfNeeded(deviceId: String) async {
        guard isRotationDue() else {
            Log.debug("🔑 SPK rotation not due yet", category: "SPKRotation")
            return
        }
        Log.info("🔑 SPK rotation due — starting atomic rotation", category: "SPKRotation")
        do {
            try await performAtomicRotation(deviceId: deviceId, reason: .scheduled)
        } catch {
            Log.error("❌ SPK rotation failed: \(error)", category: "SPKRotation")
        }
    }

    /// Force rotation regardless of schedule (e.g., triggered by security event).
    func forceRotate(deviceId: String, reason: Shared_Proto_Services_V1_SignedPreKeyRotationReason) async throws {
        Log.info("🔑 Force SPK rotation requested (reason: \(reason))", category: "SPKRotation")
        try await performAtomicRotation(deviceId: deviceId, reason: reason)
    }

    // MARK: - Core Rotation Logic

    /// Atomically rotate both SPKs:
    ///  1. Rust core generates new X25519 SPK (in-core — old key kept for grace period)
    ///  2. PQCKeyManager generates new Kyber SPK in memory (NOT yet in Keychain)
    ///  3. Both uploaded in ONE RotateSignedPreKeyRequest RPC
    ///  4. On server success → commit Kyber SPK to Keychain
    ///  5. Persist Rust core state and update last-rotation timestamp
    private func performAtomicRotation(
        deviceId: String,
        reason: Shared_Proto_Services_V1_SignedPreKeyRotationReason
    ) async throws {
        guard let core = CryptoManager.shared.core else {
            throw PreKeyRotationError.cryptoCoreNotInitialized
        }

        // ── Phase 1: generate both keys ──────────────────────────────────────

        // Classic SPK: Rust core rotates internally and returns new public material
        let rotatedSpk = try core.rotateSignedPrekey()
        guard let classicPubData = Data(base64Encoded: rotatedSpk.publicKey),
              let classicSigData = Data(base64Encoded: rotatedSpk.signature) else {
            throw PreKeyRotationError.invalidKeyMaterial
        }
        let classicKey = (keyId: rotatedSpk.keyId, publicKey: classicPubData, signature: classicSigData)

        // Kyber SPK: generated in memory only — NOT committed yet
        let kyberInMemory = try PQCKeyManager.shared.generateKyberSPKInMemory()
        let kyberSig = try PQCKeyManager.signKyberKey(publicKey: kyberInMemory.publicKey, core: core)
        let kyberKey = (keyId: kyberInMemory.keyId, publicKey: kyberInMemory.publicKey, signature: kyberSig)

        Log.info("🔑 SPK rotation: classic keyId=\(classicKey.keyId) kyber keyId=\(kyberKey.keyId)", category: "SPKRotation")

        // ── Phase 2: single atomic RPC ───────────────────────────────────────

        _ = try await KeyServiceClient.shared.rotateSignedPreKey(
            deviceId: deviceId,
            newClassicKey: classicKey,
            newKyberKey: kyberKey,
            reason: reason
        )

        // ── Phase 3: commit on success ───────────────────────────────────────

        // Only write Kyber to Keychain AFTER the server confirmed the rotation.
        // Classic SPK is already updated inside the Rust core; we persist its state.
        try PQCKeyManager.shared.commitKyberSPK(
            publicKey: kyberInMemory.publicKey,
            secretKey: kyberInMemory.secretKey,
            keyId: kyberInMemory.keyId
        )
        CryptoManager.shared.persistCoreState()

        recordRotation()
        Log.info("✅ SPK rotation complete: classic keyId=\(classicKey.keyId), kyber keyId=\(kyberKey.keyId)", category: "SPKRotation")
    }

    // MARK: - Schedule Helpers

    private func isRotationDue() -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.lastRotationKey)
        guard last > 0 else { return true }  // Never rotated
        let daysSince = (Date().timeIntervalSince1970 - last) / 86400
        return daysSince >= Self.rotationIntervalDays
    }

    private func recordRotation() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRotationKey)
    }
}

// MARK: - Errors

enum PreKeyRotationError: Error, LocalizedError {
    case cryptoCoreNotInitialized
    case invalidKeyMaterial
    case keychainCommitFailed

    var errorDescription: String? {
        switch self {
        case .cryptoCoreNotInitialized: return "Crypto core not initialized"
        case .invalidKeyMaterial:       return "Invalid rotated SPK key material from Rust core"
        case .keychainCommitFailed:     return "Failed to commit rotated Kyber SPK to Keychain"
        }
    }
}
