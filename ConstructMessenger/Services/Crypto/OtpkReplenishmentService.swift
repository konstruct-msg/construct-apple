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
    @discardableResult
    static func generateAndUpload(count: UInt32, deviceId: String) async throws -> Int {
        guard let core = CryptoManager.shared.core else {
            throw CryptoManagerError.coreNotInitialized
        }

        let pairs = try core.generateOneTimePrekeys(count: count)
        guard !pairs.isEmpty else { return 0 }

        let preKeys = pairs.map { pair -> (keyId: UInt32, publicKey: Data) in
            (keyId: pair.keyId, publicKey: Data(pair.publicKey))
        }

        _ = try await KeyServiceClient.shared.uploadPreKeys(
            deviceId: deviceId,
            preKeys: preKeys
        )

        Log.info("✅ OTPK upload: \(pairs.count) keys for device \(deviceId.prefix(8))...", category: "OTPK")
        return pairs.count
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
