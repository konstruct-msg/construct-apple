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
import GRPCCore

enum MlsKeyPackageService {

    /// Minimum KeyPackages to keep on the server; replenish below this.
    /// The server's `recommendedMinimum` wins when higher.
    static let lowWaterMark: UInt32 = 10
    /// Batch size for a replenish upload (proto recommends publishing 20+).
    static let batchSize: UInt32 = 20
    /// Minimum seconds between successful replenishment checks (race condition dedup).
    private static let cooldownSeconds: TimeInterval = 60
    /// Max attempts for a single replenish (count + publish) when the gateway blips 502.
    private static let maxAttempts = 3
    private nonisolated(unsafe) static var isReplenishing = false
    private nonisolated(unsafe) static var lastReplenishDate: Date?

    // MARK: - Replenishment (startup / post-consume)

    /// Check the server-side KeyPackage count; publish a batch if below the
    /// low-water mark. Non-fatal — logs errors instead of throwing.
    /// Transient gateway failures (502 / unavailable / deadline) are retried with
    /// short backoff so a one-shot MLS upstream blip does not leave the pool empty
    /// until the next app launch.
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
        defer { isReplenishing = false }

        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await replenishOnce(userId: userId, deviceId: deviceId)
                lastReplenishDate = Date()
                return
            } catch {
                lastError = error
                let transient = isTransientGatewayError(error)
                if transient, attempt < maxAttempts {
                    let delay = Double(attempt) // 1s, 2s
                    Log.info(
                        "MLS key package replenishment transient fail (attempt \(attempt)/\(maxAttempts)) — retry in \(Int(delay))s: \(error)",
                        category: "MLS"
                    )
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                // Terminal failure: do not set full cooldown on pure gateway blips so
                // the next stream/session check can try again (~15s soft floor).
                if transient {
                    lastReplenishDate = Date().addingTimeInterval(-(cooldownSeconds - 15))
                    Log.error(
                        "MLS key package replenishment failed after \(attempt) attempt(s) (non-fatal, gateway?): \(error)",
                        category: "MLS"
                    )
                } else {
                    lastReplenishDate = Date()
                    Log.error("MLS key package replenishment failed (non-fatal): \(error)", category: "MLS")
                }
                return
            }
        }
        if let lastError {
            Log.error("MLS key package replenishment failed (non-fatal): \(lastError)", category: "MLS")
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

    // MARK: - Private

    private static func replenishOnce(userId: String, deviceId: String) async throws {
        let status = try await MLSServiceClient.shared.getKeyPackageCount(
            userId: userId,
            deviceId: deviceId
        )
        let effective = max(status.recommendedMinimum, lowWaterMark)
        Log.debug("MLS key package server count: \(status.count) / recommended min: \(effective)", category: "MLS")
        guard status.count < effective else { return }

        if status.cannotBeInvited {
            Log.info(
                "MLS: zero key packages on server — user cannot be invited to groups until publish completes",
                category: "MLS"
            )
        }
        let uploadCount = max(batchSize, effective - status.count)
        try await generateAndPublish(count: uploadCount, deviceId: deviceId)
    }

    /// Gateway/proxy blips (502, unavailable, deadline) vs permanent application errors.
    private static func isTransientGatewayError(_ error: Error) -> Bool {
        if let rpc = error as? RPCError {
            switch rpc.code {
            case .unavailable, .deadlineExceeded, .resourceExhausted, .aborted:
                return true
            case .internalError, .unknown:
                // Caddy/envoy often surface 502 as unavailable or as message text.
                let msg = rpc.message.lowercased()
                return msg.contains("502")
                    || msg.contains("bad gateway")
                    || msg.contains("503")
                    || msg.contains("gateway")
            default:
                let msg = rpc.message.lowercased()
                return msg.contains("502") || msg.contains("bad gateway") || msg.contains("503")
            }
        }
        let desc = "\(error)".lowercased()
        return desc.contains("502")
            || desc.contains("bad gateway")
            || desc.contains("503")
            || desc.contains("unavailable")
            || desc.contains("timed out")
            || desc.contains("timeout")
    }
}
