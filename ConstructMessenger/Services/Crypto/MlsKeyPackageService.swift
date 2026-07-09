//
//  MlsKeyPackageService.swift
//  Construct Messenger
//
//  Manages MLS KeyPackage lifecycle (mirrors OtpkReplenishmentService for OTPKs):
//    - Replenishment at startup when the server pool drops below the low-water mark
//
//  KeyPackages are the MLS analogue of one-time prekeys: single-use, consumed by
//  the server when another member invites this device to a group. A user with
//  zero KeyPackages cannot be invited to any group.
//
//  Ordering is load-bearing: the store snapshot (which holds the KeyPackages'
//  private keys) is persisted BEFORE upload, inside
//  `MlsStoreManager.generateKeyPackages`. A published KeyPackage whose private
//  keys were lost makes every Welcome built on it permanently undecryptable.
//

import Foundation

enum MlsKeyPackageService {

    /// Minimum KeyPackages to keep on the server; replenish below this.
    /// The server's `recommendedMinimum` wins when higher.
    static let lowWaterMark: UInt32 = 10
    /// Batch size for a replenish upload (proto recommends publishing 20+).
    static let batchSize: UInt32 = 20
    /// Minimum seconds between replenishment checks (race condition dedup).
    private static let cooldownSeconds: TimeInterval = 60
    private nonisolated(unsafe) static var isReplenishing = false
    private nonisolated(unsafe) static var lastReplenishDate: Date?

    // MARK: - Replenishment (startup / post-consume)

    /// Check the server-side KeyPackage count; publish a batch if below the
    /// low-water mark. Non-fatal — logs errors instead of throwing.
    static func replenishIfNeeded(deviceId: String) async {
        // Signer keys come from the OrchestratorCore; before it exists the store
        // cannot be created. Callers re-run this after core init (startup check).
        guard CryptoManager.shared.isCoreReady else {
            Log.debug("MLS key package check skipped — core not initialized yet", category: "MLS")
            return
        }
        guard let userId = await AuthSessionManager.shared.currentUserId, !userId.isEmpty else {
            Log.debug("MLS key package check skipped — no local user id", category: "MLS")
            return
        }
        guard !isReplenishing else {
            Log.debug("MLS key package replenishment already in progress, skipping", category: "MLS")
            return
        }
        if let last = lastReplenishDate, Date().timeIntervalSince(last) < cooldownSeconds {
            Log.debug("MLS key package check skipped — cooldown active (\(Int(cooldownSeconds))s)", category: "MLS")
            return
        }
        isReplenishing = true
        lastReplenishDate = Date()
        defer { isReplenishing = false }

        do {
            let status = try await MLSServiceClient.shared.getKeyPackageCount(
                userId: userId,
                deviceId: deviceId
            )
            let effective = max(status.recommendedMinimum, lowWaterMark)
            Log.debug("MLS key package server count: \(status.count) / recommended min: \(effective)", category: "MLS")
            guard status.count < effective else { return }

            if status.cannotBeInvited {
                Log.info("MLS: zero key packages on server — user cannot be invited to groups until publish completes", category: "MLS")
            }
            let uploadCount = max(batchSize, effective - status.count)
            try await generateAndPublish(count: uploadCount, deviceId: deviceId)
        } catch {
            Log.error("MLS key package replenishment failed (non-fatal): \(error)", category: "MLS")
        }
    }

    // MARK: - Publish

    /// Generate `count` KeyPackages (persisting the store first) and publish them.
    /// Returns the number published.
    @discardableResult
    static func generateAndPublish(count: UInt32, deviceId: String) async throws -> Int {
        let packages = try MlsStoreManager.shared.generateKeyPackages(count: Int(count))
        guard !packages.isEmpty else { return 0 }

        let serverTotal = try await MLSServiceClient.shared.publishKeyPackages(
            deviceId: deviceId,
            keyPackages: packages
        )
        Log.info("MLS key packages published: +\(packages.count) (server now holds \(serverTotal))", category: "MLS")
        return packages.count
    }
}
