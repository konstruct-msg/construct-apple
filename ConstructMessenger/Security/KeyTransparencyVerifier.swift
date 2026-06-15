//
//  KeyTransparencyVerifier.swift
//  Construct Messenger
//
//  RFC 6962-style Merkle inclusion proof verifier.
//  Algorithm must match key-service/src/kt.rs exactly:
//
//    Identity leaf : SHA-256(0x00 || device_id_utf8 || identity_key_raw)
//    Hybrid   leaf : SHA-256(0x02 || device_id_utf8 || hybrid_identity_key)
//    Node hash     : SHA-256(0x01 || left_hash || right_hash)
//    split(n)      : largest power-of-2 strictly less than n (n >= 2)
//
//  The server signs the Signed Tree Head (STH) with its Ed25519 bundle key:
//    "ConstructKT-v1" || tree_size (8 bytes BE) || root_hash (32 bytes)
//

import CryptoKit
import Foundation

// MARK: - Public types

enum KTVerificationResult: Equatable {
    case verified
    case failed(KTVerificationError)
    case unavailable
}

enum KTVerificationError: Error, Equatable, ApplicationLayerError {
    case malformedProof
    case inclusionProofInvalid
    case rootMismatch
    case signatureInvalid
    case treeHeadKeyMissing
}

// MARK: - Verifier

struct KeyTransparencyVerifier {

    // MARK: Hash primitives

    /// Leaf hash with a domain byte: 0x00 for the identity leaf, 0x02 for the hybrid leaf.
    private static func leafHash(domain: UInt8, deviceId: String, key: Data) -> Data {
        var buf = Data([domain])
        buf.append(deviceId.data(using: .utf8)!)
        buf.append(key)
        return Data(SHA256.hash(data: buf))
    }

    private static func nodeHash(_ left: Data, _ right: Data) -> Data {
        var buf = Data([0x01])
        buf.append(left)
        buf.append(right)
        return Data(SHA256.hash(data: buf))
    }

    /// Largest power-of-2 strictly less than `n` (n >= 2).
    private static func split(_ n: Int) -> Int {
        precondition(n >= 2)
        var k = 1
        while k < n { k <<= 1 }
        return k >> 1
    }

    // MARK: Inclusion proof reconstruction (mirrors `inclusion_reconstruct` in Rust)

    /// Reconstruct the Merkle root from a leaf + RFC 6962 inclusion proof.
    /// Returns `nil` if the proof length is inconsistent with (index, treeSize).
    private static func reconstructRoot(
        leaf: Data,
        proof: [Data],
        index: Int,
        size: Int
    ) -> Data? {
        if proof.isEmpty {
            guard size == 1, index == 0 else { return nil }
            return leaf
        }
        let k = split(size)
        let sibling = proof[proof.count - 1]
        let inner = Array(proof.prefix(proof.count - 1))
        if index < k {
            guard let left = reconstructRoot(leaf: leaf, proof: inner, index: index, size: k) else { return nil }
            return nodeHash(left, sibling)
        } else {
            guard let right = reconstructRoot(leaf: leaf, proof: inner, index: index - k, size: size - k) else { return nil }
            return nodeHash(sibling, right)
        }
    }

    // MARK: STH signable bytes

    private static func treeHeadSignable(treeSize: UInt64, rootHash: Data) -> Data {
        var buf = Data("ConstructKT-v1".utf8)
        var be = treeSize.bigEndian
        buf.append(Data(bytes: &be, count: 8))
        buf.append(rootHash)
        return buf
    }

    // MARK: - Main verify entry point

    /// Verify a Key Transparency inclusion proof received with a pre-key bundle.
    ///
    /// - Parameters:
    ///   - proof: The `KtInclusionProof` proto message fields.
    ///   - deviceId: The device ID whose identity key is being verified.
    ///   - identityKey: The raw identity key bytes from the bundle.
    ///   - serverBundleSigningPublicKey: Ed25519 public key from `/.well-known/construct-server`.
    static func verify(
        leafIndex: UInt64,
        treeSize: UInt64,
        rootHash: Data,
        proofHashes: [Data],
        treeHeadSignature: Data,
        deviceId: String,
        identityKey: Data,
        serverBundleSigningPublicKey: Data?
    ) -> KTVerificationResult {
        let lhash = leafHash(domain: 0x00, deviceId: deviceId, key: identityKey)
        return verifyProof(
            leaf: lhash,
            leafIndex: leafIndex,
            treeSize: treeSize,
            rootHash: rootHash,
            proofHashes: proofHashes,
            treeHeadSignature: treeHeadSignature,
            serverBundleSigningPublicKey: serverBundleSigningPublicKey
        )
    }

    /// Verify a Key Transparency inclusion proof for the device's HYBRID identity key
    /// (leaf kind 1, domain byte 0x02). Same Merkle tree / STH as the identity proof.
    static func verifyHybrid(
        leafIndex: UInt64,
        treeSize: UInt64,
        rootHash: Data,
        proofHashes: [Data],
        treeHeadSignature: Data,
        deviceId: String,
        hybridIdentityKey: Data,
        serverBundleSigningPublicKey: Data?
    ) -> KTVerificationResult {
        let lhash = leafHash(domain: 0x02, deviceId: deviceId, key: hybridIdentityKey)
        return verifyProof(
            leaf: lhash,
            leafIndex: leafIndex,
            treeSize: treeSize,
            rootHash: rootHash,
            proofHashes: proofHashes,
            treeHeadSignature: treeHeadSignature,
            serverBundleSigningPublicKey: serverBundleSigningPublicKey
        )
    }

    /// Shared inclusion-proof + STH verification for a precomputed leaf hash.
    private static func verifyProof(
        leaf: Data,
        leafIndex: UInt64,
        treeSize: UInt64,
        rootHash: Data,
        proofHashes: [Data],
        treeHeadSignature: Data,
        serverBundleSigningPublicKey: Data?
    ) -> KTVerificationResult {

        // 1. Basic sanity
        guard treeSize > 0, leafIndex < treeSize,
              rootHash.count == 32,
              proofHashes.allSatisfy({ $0.count == 32 }) else {
            return .failed(.malformedProof)
        }

        // 2. Leaf hash supplied by the caller (identity or hybrid domain).
        let lhash = leaf

        // 3. Reconstruct root from inclusion proof
        let reconstructed = reconstructRoot(
            leaf: lhash,
            proof: proofHashes,
            index: Int(leafIndex),
            size: Int(treeSize)
        )
        guard let reconstructed else {
            return .failed(.inclusionProofInvalid)
        }
        guard reconstructed == rootHash else {
            return .failed(.rootMismatch)
        }

        // 4. Verify the Signed Tree Head
        guard let pubKeyBytes = serverBundleSigningPublicKey else {
            // Server signing key not yet fetched from .well-known (first launch, no network).
            // This is a configuration gap, not evidence of tampering — return unavailable.
            return .unavailable
        }
        guard let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) else {
            // Key bytes present in UserDefaults but malformed — likely data corruption.
            return .unavailable
        }
        let signable = treeHeadSignable(treeSize: treeSize, rootHash: rootHash)
        guard pubKey.isValidSignature(treeHeadSignature, for: signable) else {
            return .failed(.signatureInvalid)
        }

        return .verified
    }
}
