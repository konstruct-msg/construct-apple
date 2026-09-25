//
//  KyberPrekeyService.swift
//  Construct Messenger
//
//  The device's Kyber prekeys (ML-KEM-1024, PQXDH v2) on this side of the seam: persisting the
//  core's store, publishing the signed prekey, and carrying one-time keys to the server.
//
//  The core generates, signs and holds every Kyber key; the seeds never leave it, and the
//  handshake decapsulates inside it. What is left here is what only the app can do — Keychain and
//  network — and the order they must happen in:
//
//  - A Kyber key reaches the server with two signatures over `created_at || public key`: Ed25519
//    and hybrid (Ed25519 + ML-DSA-65). The server checks the hybrid one against the hybrid
//    identity key already on the device's row, and an initiator refuses a Kyber key without it.
//    So the first Kyber SPK is published in the same `UploadPreKeys` as the hybrid identity, and
//    one-time Kyber keys are only sent once that identity is published.
//  - The server serves a classic and a Kyber one-time key together and expires both pools
//    together on a replace-all. One-time Kyber keys therefore ride on the classic uploads, the
//    same count each time (`OtpkReplenishmentService`), and the two pools stay in step without
//    a second count RPC.
//
//  Replaces `PQCKeyManager` (ML-KEM-768 keys generated and signed in Swift, secrets in the
//  Keychain, the KEM run by the app after the handshake).
//

import Foundation
import GRPCCore

@MainActor
enum KyberPrekeyService {

    /// One-time Kyber keys sent with the first Kyber SPK. Later batches follow the classic
    /// replenishment count.
    static let initialOneTimeBatch: UInt32 = 50

    /// Retries of the SPK publish on `unavailable` within one run (startup transport churn).
    private static let transientRetries = 2

    /// The Kyber SPK (by device and key id) the server last confirmed with its hybrid signature.
    /// Keyed by both so a new identity or a rotated key publishes again.
    private static let publishedKey = "construct.kyber.v2.published"

    private static var publishTask: Task<Void, Never>?

    // MARK: - Persistence

    /// Import the persisted Kyber prekeys into a freshly created core. Returns false when a blob
    /// was there and would not import: the caller then forces a replace-all of the one-time keys,
    /// because the core has lost keys the server still serves and will reissue their ids.
    /// Called while the core is being built, before it is shared, so it needs no lock.
    nonisolated static func restore(into core: OrchestratorCore) -> Bool {
        guard let data = KeychainManager.shared.loadKyberPrekeysData(), !data.isEmpty else {
            // A device that never had v2 keys, or a fresh identity: nothing to restore.
            return true
        }
        do {
            try core.importKyberPrekeys(data: [UInt8](data))
            Log.info("Kyber prekeys restored (\(core.kyberOneTimePrekeyCount()) one-time)", category: "PQC")
            return true
        } catch {
            Log.fault("Kyber prekeys failed to import — forcing a one-time key replace-all: \(error)", category: "PQC")
            return false
        }
    }

    /// Persist the core's Kyber prekeys. Call after anything that changed them: generating,
    /// pruning, a rotation step, a responder init that burned a one-time key.
    @discardableResult
    nonisolated static func persist() -> Bool {
        do {
            let blob = Data(try CryptoManager.shared.exportKyberPrekeys())
            guard KeychainManager.shared.saveKyberPrekeys(blob) else {
                Log.error("PERSIST-FAIL Kyber prekeys (\(blob.count)B)", category: "PQC")
                return false
            }
            return true
        } catch {
            Log.error("Kyber prekeys export failed: \(error)", category: "PQC")
            return false
        }
    }

    /// Persist the blob a responder init handed back (`SessionInitResult.kyberPrekeys`, set when
    /// the init burned a one-time key). Same bytes `persist()` would export.
    nonisolated static func persist(blob: [UInt8]) {
        if !KeychainManager.shared.saveKyberPrekeys(Data(blob)) {
            Log.error("PERSIST-FAIL Kyber prekeys after a responder init (\(blob.count)B) — the burned key comes back on restart", category: "PQC")
        }
    }

    /// Keychain items builds before PQXDH v2 wrote outside the core. Nothing reads them.
    nonisolated static func deleteLegacyItems() {
        for key in ["construct.kyber.spk.public", "construct.kyber.spk.secret", "construct.kyber.spk.id",
                    "construct.kyber_session_state"] {
            KeychainManager.shared.deleteData(forKey: key)
        }
        let otpks = KeychainManager.shared.deleteItems(withAccountPrefix: "construct.kyber.otpk.sk.")
        let deferred = KeychainManager.shared.deleteItems(withAccountPrefix: "construct.pq_deferred.")
        KeychainManager.shared.deleteItems(withAccountPrefix: "construct.pqxdh.downgraded.")
        UserDefaults.standard.removeObject(forKey: "construct.kyber.otpk.nextKeyId")
        UserDefaults.standard.removeObject(forKey: "pqcKyberSPKMigrationV1Done")
        if otpks + deferred > 0 {
            Log.info("PQC: removed \(otpks) ML-KEM-768 one-time secrets and \(deferred) deferred contributions left by an older build", category: "PQC")
        }
    }

    // MARK: - One-time keys alongside the classic ones

    /// One-time Kyber keys to send in the same `UploadPreKeys` as `count` classic ones, already
    /// persisted. Empty when the server could not verify them yet (hybrid identity not published)
    /// or the core cannot sign them — the classic upload goes ahead either way, and an initiator
    /// then uses the Kyber SPK.
    static func oneTimeKeysForUpload(count: UInt32) -> [KyberPrekeyUpload] {
        guard count > 0, HybridIdentityService.isHybridIdentityPublished else { return [] }
        do {
            let keys = try CryptoManager.shared.generateKyberOneTimePrekeys(count: count)
            // Before the upload, as with the classic keys: a key the server may serve must never
            // exist only in memory.
            guard persist() else { return [] }
            return keys
        } catch {
            Log.error("Kyber one-time keys not generated (classic upload continues): \(error)", category: "PQC")
            return []
        }
    }

    /// After a replace-all upload that carried `uploaded`: drop the local keys the server can no
    /// longer serve, with the classic grace window.
    static func afterReplaceAll(uploaded: [KyberPrekeyUpload]) {
        guard let cutoff = OtpkReplenishmentService.pruneCutoff(
            replaceExisting: true,
            minNewId: uploaded.map(\.keyId).min()
        ) else { return }
        let pruned = CryptoManager.shared.pruneKyberOneTimePrekeys(below: cutoff)
        if pruned > 0 {
            Log.info("Kyber one-time keys: pruned \(pruned) below id \(cutoff)", category: "PQC")
            persist()
        }
    }

    // MARK: - Signed prekey

    /// Publish the Kyber SPK if the server does not have it confirmed yet — at registration and
    /// on every launch. Concurrent callers share one run.
    static func publishIfNeeded(deviceId: String) async {
        if let running = publishTask {
            await running.value
            return
        }
        let task = Task { await publish(deviceId: deviceId) }
        publishTask = task
        await task.value
        publishTask = nil
    }

    private static func published(deviceId: String, keyId: UInt32) -> Bool {
        UserDefaults.standard.string(forKey: publishedKey) == "\(deviceId):\(keyId)"
    }

    /// Forget what was published. Device link / a fresh identity, with
    /// `HybridIdentityService.resetPublishState()`.
    nonisolated static func resetPublishState() {
        UserDefaults.standard.removeObject(forKey: publishedKey)
    }

    /// Record the Kyber SPK a rotation just stored on the server with its hybrid signature.
    static func recordPublished(deviceId: String, keyId: UInt32) {
        UserDefaults.standard.set("\(deviceId):\(keyId)", forKey: publishedKey)
    }

    private static func publish(deviceId: String) async {
        let cm = CryptoManager.shared
        guard cm.orchestratorCore != nil, !deviceId.isEmpty else { return }

        let current: KyberPrekeyUpload?
        do {
            current = try cm.currentKyberSpkUpload()
        } catch {
            Log.error("Kyber SPK: current key unreadable: \(error)", category: "PQC")
            return
        }
        if let current, published(deviceId: deviceId, keyId: current.keyId) { return }

        do {
            // The hybrid identity signs every Kyber key and must exist before the first one.
            // `ensureHybridIdentityPublicKey` creates and persists it once, then returns the same.
            let hybridPublic = try cm.ensureHybridIdentityPublicKey()
            let binding = try cm.signBundleData(cm.buildHybridIdentityBindMessage(hybridPublic: hybridPublic))

            // A device with a committed SPK republishes it (the server lost it, or an older build
            // never published it with a hybrid signature). One without starts a rotation: the
            // pending key is persisted, so a retry — this launch or the next — sends the same key.
            let spk: KyberPrekeyUpload
            if let current {
                spk = current
            } else {
                spk = try cm.beginKyberSpkRotation()
                guard persist() else { return }
            }
            let classicSpk = try cm.localBundlePublicKeys().signedPrekeyPublic
            let classicSpkHybridSignature = try? cm.signHybridPrekey(suiteId: 0x01, publicKey: classicSpk)
            // The first one-time keys go with the first SPK. A republished SPK brings none: from
            // then on they ride on the classic uploads.
            let oneTime = current == nil ? try cm.generateKyberOneTimePrekeys(count: initialOneTimeBatch) : []
            guard persist() else { return }

            do {
                try await uploadWithRetry {
                    _ = try await KeyServiceClient.shared.uploadPreKeys(
                        deviceId: deviceId,
                        kyberSignedPreKey: spk,
                        kyberOneTimePreKeys: oneTime.isEmpty ? nil : oneTime,
                        hybridIdentity: (key: hybridPublic, signature: binding),
                        signedPreKeyHybridSignature: classicSpkHybridSignature,
                        kyberSignedPreKeyHybridSignature: Data(spk.hybridSignature)
                    )
                }
            } catch {
                // A pending key the server refused outright (not a transport failure) would be
                // refused again on every launch — one that waited past the 30-day age limit, say.
                // Forget it; the next launch starts from a fresh key.
                if current == nil, !isTransient(error) {
                    cm.rollbackKyberSpkRotation()
                    persist()
                }
                throw error
            }

            if current == nil {
                cm.commitKyberSpkRotation()
                persist()
            }
            recordPublished(deviceId: deviceId, keyId: spk.keyId)
            // The same request published the hybrid identity and, when it could be signed, the
            // classic SPK's hybrid signature.
            if classicSpkHybridSignature != nil {
                HybridIdentityService.recordHybridPublished(spkPublic: classicSpk)
            }
            Log.info("Kyber SPK published (keyId=\(spk.keyId), \(oneTime.count) one-time keys)", category: "PQC")
        } catch {
            Log.error("Kyber SPK publish failed (next launch retries): \(error)", category: "PQC")
        }
    }

    /// A failure that says nothing about whether the server stored the upload.
    private static func isTransient(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return true }
        return [.unavailable, .deadlineExceeded, .cancelled, .unknown].contains(rpc.code)
    }

    private static func uploadWithRetry(_ upload: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do {
                try await upload()
                return
            } catch {
                guard (error as? RPCError)?.code == .unavailable, attempt < transientRetries else { throw error }
                attempt += 1
                try? await Task.sleep(for: .seconds(Double(attempt) * 2.0))
            }
        }
    }
}
