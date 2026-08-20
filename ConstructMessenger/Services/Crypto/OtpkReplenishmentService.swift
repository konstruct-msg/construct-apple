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
    /// Default batch for force-replace uploads (registration, fresh-orchestrator reset).
    static let replenishBatchSize: UInt32 = 50
    /// Minimum seconds between replenishment calls (race condition dedup).
    private static let cooldownSeconds: TimeInterval = 60
    /// After a replace-all upload, keep this many IDs below the new batch so first messages
    /// already in flight still decrypt: a peer that fetched a bundle moments before the replace
    /// holds that key and will use it, even though the server stopped serving it the instant
    /// `replace_existing=true` set `is_expired`. (The server's 48 h interval is a hard-delete
    /// sweep of already-expired rows — it is NOT a window in which they keep being handed out.)
    /// Everything below the window is pruned so the persisted blob stays bounded.
    ///
    /// Applies to `replaceExisting` uploads ONLY — on an append the server retires nothing,
    /// so an id cutoff would delete privates for keys it still serves.
    private static let pruneGraceWindow: UInt32 = 200
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

        // Prune stale local privates — REPLACE-ALL ONLY.
        //
        // A local private may be deleted only once the server can no longer hand out its
        // public half. The server deletes a key when it is consumed; an *unconsumed* key
        // lives until the pool is replaced, and `key-service` soft-expires the old pool
        // strictly under `replace_existing=true`. So the id-cutoff reasoning below holds
        // for a replace, and for nothing else.
        //
        // What made the append case fire so reliably rather than occasionally: the server
        // hands out `ORDER BY uploaded_at ASC` — oldest unconsumed key first — while an id
        // cutoff deletes oldest-first too. The two are exactly anti-correlated, so a prune
        // took out precisely the keys the server was about to serve next.
        //
        // `bcbab02f` extended this to the append path to stop the persisted blob hoarding
        // (a device was observed holding 2294 privates while the server reported 0). That
        // applied replace-all reasoning to the one path where the server retires nothing:
        // every 20-key append deleted privates for keys the server was still serving. When
        // a peer's bundle fetch then drew one, its 4-DH init could not be reproduced —
        // `OTPK id=… not found` → END_SESSION → forced 3-DH re-init. This is the source of
        // the "sessions break at random" reports; observed 2026-08-01 with the sender on
        // id 1003070 and the receiver pruned below 1003210.
        //
        // Reverting restores the hoarding problem. That is the correct trade for now —
        // an oversized Keychain blob is a cost, an unreproducible OTPK is lost delivery.
        // The bounded-and-correct design is a periodic replace-all; see
        // decisions/otpk-pool-lifecycle.
        //
        // `pruneGraceWindow` keys below the new batch are kept so first messages already in
        // flight against just-replaced keys still decrypt, covered by the server's 48 h
        // soft-expiry; anything older can never be referenced again.
        if let cutoff = pruneCutoff(replaceExisting: replaceExisting, minNewId: pairs.map(\.keyId).min()) {
            let pruned = CryptoManager.shared.pruneOneTimePrekeys(below: cutoff)
            if pruned > 0 {
                Log.info("OTPK pruned \(pruned) stale local keys below id \(cutoff) (\(CryptoManager.shared.oneTimePrekeyCount()) remain, mode=\(mode))", category: "OTPK")
                persistOtpks()
            }
        }
        return pairs.count
    }

    /// Highest OTPK id it is safe to delete locally after an upload, or `nil` to prune nothing.
    ///
    /// The rule this encodes: **a local private may be dropped only once the server can no
    /// longer hand out its public half.** The server deletes a key on consumption; an unconsumed
    /// key lives until the pool is replaced, and only `replace_existing=true` soft-expires the
    /// old pool. An append retires nothing, so no id cutoff is safe there — returning `nil` is
    /// not caution, it is the only correct answer.
    ///
    /// Pure and `internal` so the rule is testable without a network round-trip; the defect it
    /// replaces lived inside one.
    static func pruneCutoff(replaceExisting: Bool, minNewId: UInt32?) -> UInt32? {
        guard replaceExisting, let minNewId else { return nil }
        return minNewId > pruneGraceWindow ? minNewId - pruneGraceWindow : 0
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

    /// Called after RESPONDER session-init failure or heal exhaustion. At most an
    /// append replenish, guarded by the server low-water mark and the shared cooldown.
    ///
    /// Never force-replace here: a failed init usually means OTPK *desync*, not
    /// depletion, and wiping the server set destroys keys that peers' in-flight inits
    /// still reference — every such init then fails too, triggering another wipe
    /// (the replace-all OTPK storm that made desync deadlocks unrecoverable).
    /// Recovery from a truly unreproducible OTPK is the typed END_SESSION reason
    /// (`.otpkUnreproducible` → peer re-inits via 3-DH), not a key wipe.
    static func replenishAfterInitFailure(deviceId: String, reason: String) async {
        if let last = lastReplenishDate, Date().timeIntervalSince(last) < cooldownSeconds {
            Log.info("OTPK replenish (\(reason)) skipped — cooldown active (\(Int(cooldownSeconds))s)", category: "OTPK")
            return
        }
        await replenishInternal(deviceId: deviceId, source: reason)
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

            // Capability re-advertisement: supports_pq_ratchet reaches the server ONLY
            // inside uploadPreKeys. When a build flips the capability (suite-3 rollout),
            // a device with a healthy server count would otherwise never re-upload —
            // peers keep fetching the stale flag and negotiate classic forever.
            #if os(iOS)
            let advertised = supportsPqRatchet()
            if KeyServiceClient.lastAdvertisedPqRatchet != advertised {
                let was = KeyServiceClient.lastAdvertisedPqRatchet.map(String.init) ?? "unknown"
                Log.info("OTPK capability changed (supportsPqRatchet \(was) → \(advertised)) — forcing upload to re-advertise [\(source)]", category: "OTPK")
                try await generateAndUpload(count: lowWaterMark, deviceId: deviceId)
                return
            }
            #endif

            guard serverCount < effective else { return }

            let uploadCount = max(lowWaterMark, effective - serverCount)
            Log.info("OTPK \(serverCount) < \(effective) — uploading \(uploadCount) keys [\(source)]...", category: "OTPK")
            try await generateAndUpload(count: uploadCount, deviceId: deviceId)
        } catch {
            Log.error("OTPK replenishment failed (non-fatal) [\(source)]: \(error)", category: "OTPK")
        }
    }
}
