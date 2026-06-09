//
//  HybridIdentityService.swift
//  ConstructMessenger
//
//  Phase 1 of PQ-signature protocol integration (client side).
//
//  Publishes the device's hybrid PQ identity bundle (Ed25519 + ML-DSA-65) to the
//  server, decoupled from key rotation:
//    - hybrid identity public key (1984 B), generated lazily on first launch;
//    - an Ed25519 cross-signature binding it to the device's existing identity;
//    - hybrid signatures over the CURRENT classic SPK (suite 0x01) and Kyber SPK (0x10).
//
//  The server (key-service `store_hybrid_identity`) verifies each signature against
//  the currently stored prekeys and never triggers a rotation. Verification is
//  capability-gated end-to-end: peers without hybrid keys keep working unchanged.
//
//  Binding model: the hybrid key's Ed25519 half is INDEPENDENT of the device
//  identity; the cross-signature is the binding. See
//  construct-docs/wiki/decisions/pq-signature-protocol-integration-plan.md.
//

import Foundation

@MainActor
enum HybridIdentityService {
    /// Domain-separation prologue for the cross-signature. MUST match the server
    /// constant `HYBRID_ID_BIND_PROLOGUE` in `key-service/src/core.rs`.
    private static let bindPrologue = "KonstruktHybridId-v1"

    /// X3DH prekey sign-message prologue (shared with the Ed25519 prekey signatures).
    private static let x3dhPrologue = "KonstruktX3DH-v1"

    /// Set once the hybrid bundle has been accepted by the server. Bump the suffix to
    /// force a one-time re-publish after a protocol change.
    private static let publishedFlagKey = "construct.hybridIdentity.published.v1"

    /// Lazily publish the hybrid identity bundle once per device. Idempotent and
    /// best-effort: on failure the flag is left unset so the next launch retries.
    static func publishIfNeeded(deviceId: String) async {
        guard !UserDefaults.standard.bool(forKey: publishedFlagKey) else { return }
        do {
            try await publish(deviceId: deviceId)
            UserDefaults.standard.set(true, forKey: publishedFlagKey)
        } catch {
            Log.error("Hybrid identity publish failed (will retry next launch): \(error.localizedDescription)", category: "HybridPQ")
        }
    }

    /// Build and upload the hybrid identity bundle over the device's current prekeys.
    /// Call directly (bypassing the once-flag) to re-attach hybrid signatures after an
    /// SPK rotation, which clears them server-side.
    static func publish(deviceId: String) async throws {
        let cm = CryptoManager.shared

        // 1. Ensure the hybrid keypair (generated + persisted on first use).
        let hybridPub = try cm.ensureHybridIdentityPublicKey() // 1984 B

        // 2. Cross-sign the hybrid key with the device Ed25519 identity.
        var bindMessage = Data(bindPrologue.utf8)
        bindMessage.append(hybridPub)
        let crossSignature = try cm.signBundleData([UInt8](bindMessage)) // 64 B Ed25519

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
        Log.info("Hybrid PQ identity published (key=\(hybridPub.count)B, spkSig=\(spkHybridSig.count)B, kyberSig=\(kyberHybridSig?.count ?? 0)B)", category: "HybridPQ")
    }

    /// `x3dhPrologue || [0x00, suite_id] || public_key` — identical bytes as the Ed25519
    /// prekey signature, signed instead with the hybrid key.
    private static func x3dhSignMessage(suiteId: UInt8, publicKey: Data) -> [UInt8] {
        var message = Data(x3dhPrologue.utf8)
        message.append(contentsOf: [0x00, suiteId])
        message.append(publicKey)
        return [UInt8](message)
    }
}
