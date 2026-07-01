//
//  HybridIdentityService.swift
//  ConstructMessenger
//
//  Phase 1 of PQ-signature protocol integration (client side).
//
//  Publishes the device's hybrid PQ identity bundle (Ed25519 + ML-DSA-65) to the
//  server, decoupled from key rotation:
//    - hybrid identity public key (1984 B), generated lazily on first launch (core-owned);
//    - an Ed25519 cross-signature binding it to the device's existing identity (core signBundle);
//    - hybrid signatures over the CURRENT classic SPK (suite 0x01) and Kyber SPK (0x10).
//
//  Crypto primitives + key ownership (ensure/sign) live in construct-core (KeyManager + CFE).
//  No hybrid signature algorithm lives outside core. The "when to publish / on rotation"
//  policy + downgrade state live here (as designed in the integration plan).
//
//  The server (key-service `store_hybrid_identity`) verifies each signature against
//  the currently stored prekeys and never triggers a rotation. Verification is
//  capability-gated end-to-end: peers without hybrid keys keep working unchanged.
//
//  Binding model: the hybrid key's Ed25519 half is INDEPENDENT of the device
//  identity; the cross-signature is the binding. See
//  decisions/pq-signature-protocol-integration-plan.md.
//

import Foundation
import CryptoKit
import GRPCCore

@MainActor
enum HybridIdentityService {
    /// Set once the hybrid bundle has been accepted by the server. Bump the suffix to
    /// force a one-time re-publish after a protocol change.
    private static let publishedFlagKey = "construct.hybridIdentity.published.v1"

    /// SHA-256 of the classic SPK the hybrid signatures were last published over.
    /// An SPK rotation clears the server-side hybrid SPK signature; comparing this
    /// against the current SPK lets `publishIfNeeded` detect that state and re-attach.
    /// Without it, a rotation whose best-effort re-attach failed (transient RPC error)
    /// left the bundle permanently unverifiable — hybrid identity present but
    /// "SPK hybrid signature missing" — because the one-time published flag made
    /// `publishIfNeeded` skip forever.
    private static let spkFingerprintKey = "construct.hybridIdentity.spkFingerprint.v1"

    /// Transient transport codes worth retrying in-session — same set the media
    /// up/download paths treat as retryable. `.cancelled`/`.unknown` cover the VEIL
    /// proxy restarting mid-stream during startup churn.
    private static let retryablePublishCodes: Set<RPCError.Code> = [.cancelled, .unavailable, .deadlineExceeded, .unknown]

    /// In-session backoff schedule. The publish lands during startup connection churn
    /// (VEIL coming up, QUIC toggle), which typically settles within ~30–60 s.
    private static let publishBackoffsNs: [UInt64] = [5_000_000_000, 15_000_000_000, 30_000_000_000]

    /// Publish the hybrid identity bundle when needed. Self-healing and best-effort:
    /// re-publishes when never published OR when the SPK has rotated since the last
    /// successful publish (stale server-side hybrid SPK signature).
    ///
    /// Retries in-session on transient transport failures (bounded backoff): the launch
    /// publish frequently lands mid startup churn, and a single transient failure used to
    /// leave the bundle unverifiable ("SPK hybrid signature missing") until the next cold
    /// launch or a server `republish_hybrid_prekeys` push — during which peers hard-reject
    /// our bundle. A permanent error (bad signature, auth) won't heal by retrying, so we
    /// bail to next-launch immediately. On final failure nothing is recorded, so the next
    /// launch still retries.
    static func publishIfNeeded(deviceId: String) async {
        let published = UserDefaults.standard.bool(forKey: publishedFlagKey)
        let current = try? currentSpkFingerprint()
        let recorded = UserDefaults.standard.string(forKey: spkFingerprintKey)
        // Up to date only when we've published AND the SPK hasn't rotated since.
        if published, let current, current == recorded { return }

        var attempt = 0
        while true {
            if Task.isCancelled { return }
            do {
                try await publish(deviceId: deviceId)
                return
            } catch {
                guard isTransientPublishFailure(error), attempt < publishBackoffsNs.count else {
                    Log.error("Hybrid identity publish failed (will retry next launch): \(error.localizedDescription)", category: "HybridPQ")
                    return
                }
                let delay = publishBackoffsNs[attempt]
                attempt += 1
                Log.info("Hybrid identity publish transient failure (attempt \(attempt)/\(publishBackoffsNs.count)) — retrying in \(delay / 1_000_000_000)s: \(error.localizedDescription)", category: "HybridPQ")
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return  // cancelled while backing off
                }
            }
        }
    }

    /// True when a publish error is a transient transport failure worth an in-session retry.
    /// A `CancellationError`/`GRPCClientError` or a non-RPC error (e.g. NWError) thrown before
    /// the call completed is transport-level; an RPCError is retryable only for the transient
    /// codes (`.unavailable`, `.deadlineExceeded`, `.cancelled`, `.unknown`). Application/auth
    /// errors (`.invalidArgument`, `.unauthenticated`, …) are permanent — do not retry.
    private static func isTransientPublishFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if error is GRPCClientError { return true }
        guard let rpc = error as? RPCError else { return true }
        return retryablePublishCodes.contains(rpc.code)
    }

    /// Build and upload the hybrid identity bundle over the device's current prekeys.
    /// Call directly (bypassing the once-flag) to re-attach hybrid signatures after an
    /// SPK rotation, which clears them server-side.
    static func publish(deviceId: String) async throws {
        let cm = CryptoManager.shared

        // 1. Ensure the hybrid keypair (generated + persisted on first use).
        let hybridPub = try cm.ensureHybridIdentityPublicKey() // 1984 B

        // 2. Cross-sign the hybrid key with the device Ed25519 identity.
        // Message construction now comes from core for single source of truth.
        let bindMessage = cm.buildHybridIdentityBindMessage(hybridPublic: hybridPub)
        let crossSignature = try cm.signBundleData(bindMessage) // 64 B Ed25519 (uses main device signing key)

        // 3. Hybrid-sign the CURRENT classic SPK (suite 0x01).
        let spkPublic = try cm.localBundlePublicKeys().signedPrekeyPublic
        let spkHybridSig = try cm.signHybrid(x3dhSignMessage(suiteId: 0x01, publicKey: spkPublic))

        // 4. Hybrid-sign the CURRENT Kyber SPK (suite 0x10), when one exists.
        var kyberHybridSig: Data?
        if let kyberPublic = try? PQCKeyManager.shared.kyberSPKPublic() {
            kyberHybridSig = try cm.signHybrid(x3dhSignMessage(suiteId: 0x10, publicKey: kyberPublic))
        }

        // 5. Upload the self-contained bundle (no rotation triggered).
        _ = try await KeyServiceClient.shared.uploadPreKeys(
            deviceId: deviceId,
            hybridIdentity: (key: hybridPub, signature: crossSignature),
            signedPreKeyHybridSignature: spkHybridSig,
            kyberSignedPreKeyHybridSignature: kyberHybridSig
        )

        // 6. Record success so publishIfNeeded can detect a later SPK rotation and
        //    re-attach. Only set AFTER the upload is acknowledged — a failed publish
        //    must leave the fingerprint stale so the next launch retries.
        UserDefaults.standard.set(true, forKey: publishedFlagKey)
        UserDefaults.standard.set(Self.fingerprint(spkPublic), forKey: spkFingerprintKey)
        Log.info("Hybrid PQ identity published (key=\(hybridPub.count)B, spkSig=\(spkHybridSig.count)B, kyberSig=\(kyberHybridSig?.count ?? 0)B)", category: "HybridPQ")
    }

    /// SHA-256 hex of the device's current classic SPK — the staleness key for the
    /// hybrid SPK signature. Rotation changes the SPK, so this changes too.
    private static func currentSpkFingerprint() throws -> String {
        let spk = try CryptoManager.shared.localBundlePublicKeys().signedPrekeyPublic
        return fingerprint(spk)
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical X3DH sign message, now obtained from core (centralized construction).
    private static func x3dhSignMessage(suiteId: UInt8, publicKey: Data) -> [UInt8] {
        return CryptoManager.shared.buildX3dhSignMessage(suiteId: suiteId, publicKey: publicKey)
    }

    /// True once the hybrid identity key + cross-signature have been published to the server.
    /// Atomic SPK-rotation hybrid signatures are only meaningful (server-verifiable) after this;
    /// before it, the server has no hybrid identity key to verify the SPK signature against.
    static var isHybridIdentityPublished: Bool {
        UserDefaults.standard.bool(forKey: publishedFlagKey)
    }

    /// Record that the hybrid SPK signature for `spkPublic` is now live server-side (e.g. it was
    /// stored atomically by SPK rotation), so `publishIfNeeded` won't redundantly re-publish on
    /// the next launch.
    static func recordHybridPublished(spkPublic: Data) {
        UserDefaults.standard.set(true, forKey: publishedFlagKey)
        UserDefaults.standard.set(fingerprint(spkPublic), forKey: spkFingerprintKey)
    }

    /// Hybrid (ML-DSA) signature over a classic SPK public key (suite 0x01). Used by SPK
    /// rotation to send the hybrid signature atomically with the rotated key.
    /// Message + sign now routed via core helpers.
    static func hybridSPKSignature(spkPublic: Data) throws -> Data {
        try CryptoManager.shared.signHybridPrekey(suiteId: 0x01, publicKey: spkPublic)
    }

    /// Hybrid (ML-DSA) signature over a Kyber SPK public key (suite 0x10).
    static func hybridKyberSPKSignature(kyberPublic: Data) throws -> Data {
        try CryptoManager.shared.signHybridPrekey(suiteId: 0x10, publicKey: kyberPublic)
    }
}
