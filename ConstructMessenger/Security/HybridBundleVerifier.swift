//
//  HybridBundleVerifier.swift
//  ConstructMessenger
//
//  Phase 2 of PQ-signature protocol integration (client side): verify-if-present.
//
//  When fetching a peer's pre-key bundle, if the hybrid PQ identity fields are present
//  this verifies the full trust chain in Swift (the Rust core only knows the Ed25519
//  path). Capability-gated: a peer WITHOUT hybrid fields is accepted unchanged
//  (Ed25519-only). A peer whose hybrid IDENTITY cross-signature fails is rejected
//  (identity tampering). A peer whose hybrid identity is authentic but whose SPK-level
//  hybrid signature is missing/invalid is DEGRADED to classic X3DH (peer SPK desync), not
//  rejected — see `.degraded` and otpk-session-init-deadlock (build 496 SPK↔hybrid).
//
//  Trust chain (see decisions/pq-signature-protocol-integration-plan.md):
//    peer Ed25519 identity (verifying_key)
//      └─ cross-sig: Ed25519(verifying_key, "KonstruktHybridId-v1" || hybrid_key)
//          └─ hybrid_key  ──hybrid_sign──> SPK (0x01) & Kyber SPK (0x10)
//

import Foundation
import CryptoKit

enum HybridBundleVerifier {
    enum Outcome: Equatable {
        case verified         // hybrid fields present and the whole chain validates
        case absent           // no hybrid identity key → Ed25519-only peer (accepted)
        case degraded(String) // hybrid IDENTITY authentic (cross-sig valid) but the SPK-level
                              // hybrid attestation is missing/invalid — proceed via classic X3DH
                              // with a warning instead of hard-blocking (peer SPK desync).
        case failed(String)   // identity-level tampering (cross-signature invalid) → reject bundle
    }

    /// Domain prologue for the cross-signature — matches the server `HYBRID_ID_BIND_PROLOGUE`
    /// and the client `HybridIdentityService.bindPrologue`.
    private static let bindPrologue = "KonstruktHybridId-v1"
    /// X3DH prekey sign-message prologue (shared with the Ed25519 prekey signatures).
    private static let x3dhPrologue = "KonstruktX3DH-v1"

    /// Verify a peer's hybrid identity bundle.
    ///
    /// - Parameters:
    ///   - hybridIdentityKey: bundle field 20 (1984 B) — empty when the peer has no hybrid key.
    ///   - hybridIdentitySignature: field 21 — Ed25519 cross-signature (64 B).
    ///   - verifyingKey: the peer device's Ed25519 identity key (verifies the cross-signature).
    ///   - signedPreKey / signedPreKeyHybridSignature: classic SPK (suite 0x01) and field 22.
    ///   - kyberPreKey / kyberPreKeyHybridSignature: Kyber SPK (suite 0x10) and field 23.
    static func verify(
        hybridIdentityKey: Data,
        hybridIdentitySignature: Data,
        verifyingKey: Data,
        signedPreKey: Data,
        signedPreKeyHybridSignature: Data,
        kyberPreKey: Data?,
        kyberPreKeyHybridSignature: Data?
    ) -> Outcome {
        // Capability gate: no hybrid key → Ed25519-only peer.
        guard !hybridIdentityKey.isEmpty else { return .absent }

        // 1. Cross-signature binds the hybrid key to the peer's Ed25519 identity.
        guard !verifyingKey.isEmpty else {
            return .failed("hybrid key present but peer verifying_key missing")
        }
        guard verifyCrossSignature(
            verifyingKey: verifyingKey,
            hybridKey: hybridIdentityKey,
            signature: hybridIdentitySignature
        ) else {
            return .failed("cross-signature invalid")
        }

        // The cross-signature above already authenticated the hybrid IDENTITY key against the
        // peer's Ed25519 identity. The SPK-level hybrid signatures below are PQ defence-in-depth
        // ON TOP of the classic Ed25519 SPK signature (which the Rust core still verifies during
        // X3DH). If they are missing/invalid the peer's SPK is desynced from its hybrid identity
        // (e.g. an SPK rotation whose RPC failed on a censored transport — build 496); that is NOT
        // identity tampering. Hard-rejecting there makes a single desynced peer permanently
        // unreachable, so we DEGRADE to classic X3DH with a warning instead. An attacker cannot
        // exploit this: forging the SPK still requires forging the classic Ed25519 SPK signature.

        // 2. Hybrid signature over the classic SPK (suite 0x01).
        guard !signedPreKeyHybridSignature.isEmpty else {
            return .degraded("SPK hybrid signature missing")
        }
        guard verifyHybridSig(
            hybridKey: hybridIdentityKey,
            suiteId: 0x01,
            publicKey: signedPreKey,
            signature: signedPreKeyHybridSignature
        ) else {
            return .degraded("SPK hybrid signature invalid")
        }

        // 3. Hybrid signature over the Kyber SPK (suite 0x10), only when one is present.
        if let kyberPK = kyberPreKey, !kyberPK.isEmpty {
            guard let kyberSig = kyberPreKeyHybridSignature, !kyberSig.isEmpty else {
                return .degraded("Kyber SPK present but hybrid signature missing")
            }
            guard verifyHybridSig(
                hybridKey: hybridIdentityKey,
                suiteId: 0x10,
                publicKey: kyberPK,
                signature: kyberSig
            ) else {
                return .degraded("Kyber SPK hybrid signature invalid")
            }
        }

        return .verified
    }

    // MARK: - Primitives

    private static func verifyCrossSignature(verifyingKey: Data, hybridKey: Data, signature: Data) -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: verifyingKey) else {
            return false
        }
        var message = Data(bindPrologue.utf8)
        message.append(hybridKey)
        return pub.isValidSignature(signature, for: message)
    }

    private static func verifyHybridSig(hybridKey: Data, suiteId: UInt8, publicKey: Data, signature: Data) -> Bool {
        var message = Data(x3dhPrologue.utf8)
        message.append(contentsOf: [0x00, suiteId])
        message.append(publicKey)
        // `hybridVerify` is a stateless construct-core free function (no actor isolation).
        return (try? hybridVerify(
            publicKey: [UInt8](hybridKey),
            message: [UInt8](message),
            signature: [UInt8](signature)
        )) ?? false
    }
}

/// Thrown when a fetched bundle carries hybrid fields that fail verification.
struct HybridBundleVerificationError: Error, LocalizedError, ApplicationLayerError {
    let reason: String
    var errorDescription: String? { "Hybrid PQ bundle verification failed: \(reason)" }
}
