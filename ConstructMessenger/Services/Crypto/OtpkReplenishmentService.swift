//
//  OtpkReplenishmentService.swift
//  Construct Messenger
//
//  Manages one-time prekey (OTPK) lifecycle:
//    - Initial upload at registration (100 keys)
//    - Replenishment after each session init as Bob (receiver)
//
//  OTPKs provide perfect forward secrecy at X3DH session establishment.
//  Each key is burn-on-use: once consumed by an incoming session, it's gone.
//  We replenish when local count drops below the low-water mark.
//

import Foundation

enum OtpkReplenishmentService {

    /// Minimum number of OTPKs to keep on the server. Replenish if below this.
    static let lowWaterMark: UInt32 = 20
    /// Batch size for replenishment uploads.
    static let replenishBatchSize: UInt32 = 50

    // MARK: - Initial upload (called once at registration)

    /// Generate `count` OTPKs and upload them. Returns the number uploaded.
    /// After a successful upload, the current OTPK set is persisted to Keychain so it
    /// survives app restarts (the Rust core's OTPK store is in-memory only otherwise).
    @discardableResult
    static func generateAndUpload(count: UInt32, deviceId: String, replaceExisting: Bool = false) async throws -> Int {
        guard let core = CryptoManager.shared.core else {
            throw CryptoManagerError.coreNotInitialized
        }

        let pairs = try core.generateOneTimePrekeys(count: count)
        guard !pairs.isEmpty else { return 0 }

        let preKeys = pairs.map { pair -> (keyId: UInt32, publicKey: Data) in
            (keyId: pair.keyId, publicKey: Data(pair.publicKey))
        }

        // Persist private keys to Keychain BEFORE uploading so they survive even if the
        // network call fails or the app is killed mid-flight.  Without this, deleteOtpksJson()
        // followed by a throw leaves the Keychain empty on the next restart, triggering the
        // full-replace fallback again and permanently destroying messages encrypted to the old set.
        if replaceExisting {
            KeychainManager.shared.deleteOtpksJson()
        }
        persistOtpks(core: core)

        _ = try await KeyServiceClient.shared.uploadPreKeys(
            deviceId: deviceId,
            preKeys: preKeys,
            replaceExisting: replaceExisting
        )

        let mode = replaceExisting ? "replacing all" : "appending"
        Log.info("✅ OTPK upload (\(mode)): \(pairs.count) keys for device \(deviceId.prefix(8))...", category: "OTPK")
        return pairs.count
    }

    /// Export all OTPKs from the Rust core and save to Keychain.
    static func persistOtpks(core: ClassicCryptoCore) {
        do {
            let json = try core.exportOneTimePrekeysJson()
            KeychainManager.shared.saveOtpksJson(json)
            Log.debug("💾 Persisted \(core.oneTimePrekeyCount()) OTPKs to Keychain", category: "OTPK")
        } catch {
            Log.error("⚠️ Failed to persist OTPKs to Keychain: \(error)", category: "OTPK")
        }
    }

    // MARK: - Replenishment (called after Bob receives a session-init message)

    /// Check server-side OTPK count; upload a batch if below the low-water mark.
    /// Non-fatal — logs errors instead of throwing.
    static func replenishIfNeeded(deviceId: String) async {
        do {
            let serverCount = try await KeyServiceClient.shared.getPreKeyCount(deviceId: deviceId)
            Log.debug("🔑 OTPK server count: \(serverCount)", category: "OTPK")

            guard serverCount < lowWaterMark else { return }

            Log.info("🔑 OTPK count \(serverCount) < \(lowWaterMark) — replenishing \(replenishBatchSize)...", category: "OTPK")
            try await generateAndUpload(count: replenishBatchSize, deviceId: deviceId)
        } catch {
            Log.error("⚠️ OTPK replenishment failed (non-fatal): \(error)", category: "OTPK")
        }
    }
}
