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
    /// Default batch for force-replace uploads (registration, session-init failure).
    static let replenishBatchSize: UInt32 = 50
    /// Minimum seconds between replenishment calls (race condition dedup).
    private static let cooldownSeconds: TimeInterval = 60
    private nonisolated(unsafe) static var isReplenishing = false
    private nonisolated(unsafe) static var lastReplenishDate: Date?

    // MARK: - Initial upload (called once at registration)

    /// Generate `count` OTPKs and upload them. Returns the number uploaded.
    /// After a successful upload, the current OTPK set is persisted to Keychain so it
    /// survives app restarts (the Rust core's OTPK store is in-memory only otherwise).
    @discardableResult
    static func generateAndUpload(count: UInt32, deviceId: String, replaceExisting: Bool = false) async throws -> Int {
        let pairs = try CryptoManager.shared.generateOneTimePrekeys(count: count)
        guard !pairs.isEmpty else { return 0 }

        let preKeys = pairs.map { pair -> (keyId: UInt32, publicKey: Data) in
            (keyId: pair.keyId, publicKey: Data(pair.publicKey))
        }

        // Persist private keys to Keychain BEFORE uploading so they survive even if the
        // network call fails or the app is killed mid-flight.  Without this, deleteOtpks()
        // followed by a throw leaves the Keychain empty on the next restart, triggering the
        // full-replace fallback again and permanently destroying messages encrypted to the old set.
        if replaceExisting {
            KeychainManager.shared.deleteOtpks()
        }
        persistOtpks()

        _ = try await KeyServiceClient.shared.uploadPreKeys(
            deviceId: deviceId,
            preKeys: preKeys,
            replaceExisting: replaceExisting
        )

        let mode = replaceExisting ? "replacing all" : "appending"
        Log.info("OTPK upload (\(mode)): \(pairs.count) keys for device \(deviceId.prefix(8))...", category: "OTPK")
        if replaceExisting {
            CryptoManager.shared.clearNeedsFullOtpkReplacement()
        }
        return pairs.count
    }

    /// Export all OTPKs from the Rust core and save to Keychain (serialized via coreLock).
    static func persistOtpks() {
        do {
            let data = Data(try CryptoManager.shared.exportOneTimePrekeys())
            KeychainManager.shared.saveOtpks(data)
            Log.debug("Persisted \(CryptoManager.shared.oneTimePrekeyCount()) OTPKs (CFE) to Keychain", category: "OTPK")
        } catch {
            Log.error("Failed to persist OTPKs to Keychain: \(error)", category: "OTPK")
        }
    }

    // MARK: - Replenishment (called after Bob receives a session-init message)

    /// Check server-side OTPK count; upload a batch if below the low-water mark.
    /// Uses smart upload count: `max(0, recommendedMinimum - serverCount)`, minimum 20.
    /// Non-fatal — logs errors instead of throwing.
    static func replenishIfNeeded(deviceId: String) async {
        await replenishInternal(deviceId: deviceId, source: "startup/session")
    }

    /// Called from background push handler (activity_type = "replenish_prekeys").
    /// Identical to replenishIfNeeded but skips the cooldown once to ensure the push
    /// always results in at least one check. Subsequent pushes within the cooldown window
    /// are dropped to prevent simultaneous-writer race conditions.
    static func replenishForPush(deviceId: String) async {
        if let last = lastReplenishDate, Date().timeIntervalSince(last) < cooldownSeconds {
            Log.info("OTPK replenish push skipped — cooldown active (\(Int(cooldownSeconds))s)", category: "OTPK")
            return
        }
        await replenishInternal(deviceId: deviceId, source: "push")
    }

    private static func replenishInternal(deviceId: String, source: String) async {
        guard !isReplenishing else {
            Log.debug("OTPK replenishment already in progress, skipping (\(source))", category: "OTPK")
            return
        }
        isReplenishing = true
        lastReplenishDate = Date()
        defer { isReplenishing = false }
        do {
            // If the orchestrator was freshly initialized (no prior CFE state), next_otpk_id
            // reset to 1,000,000 and the server may hold OTPKs from an older session with
            // the same IDs but different key material.  Replace all server OTPKs regardless
            // of the current server count so every ID on the server matches our private keys.
            let forceReplace = CryptoManager.shared.needsFullOtpkReplacement
            if forceReplace {
                Log.info("Fresh orchestrator detected — replacing all server OTPKs [\(source)]", category: "OTPK")
                try await generateAndUpload(count: replenishBatchSize, deviceId: deviceId, replaceExisting: true)
                return
            }

            let (serverCount, recommendedMin) = try await KeyServiceClient.shared.getPreKeyCountFull(deviceId: deviceId)
            let effective = max(recommendedMin, lowWaterMark)
            Log.debug("OTPK server count: \(serverCount) / recommended min: \(effective) [\(source)]", category: "OTPK")

            guard serverCount < effective else { return }

            let uploadCount = max(lowWaterMark, effective - serverCount)
            Log.info("OTPK \(serverCount) < \(effective) — uploading \(uploadCount) keys [\(source)]...", category: "OTPK")
            try await generateAndUpload(count: uploadCount, deviceId: deviceId)
        } catch {
            Log.error("OTPK replenishment failed (non-fatal) [\(source)]: \(error)", category: "OTPK")
        }
    }
}
