//
//  KeyTransparencyVerifier.swift
//  Construct Messenger
//
//  RFC 6962-style Merkle inclusion proof verifier.
//  Algorithm must match key-service/src/kt.rs exactly:
//
//    Leaf hash : SHA-256(0x00 || device_id_utf8 || identity_key_raw)
//    Node hash : SHA-256(0x01 || left_hash || right_hash)
//    split(n)  : largest power-of-2 strictly less than n (n >= 2)
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

enum KTVerificationError: Error, Equatable {
    case malformedProof
    case inclusionProofInvalid
    case rootMismatch
    case signatureInvalid
    case treeHeadKeyMissing
}

// MARK: - Verifier

struct KeyTransparencyVerifier {

    // MARK: Hash primitives

    private static func leafHash(deviceId: String, identityKey: Data) -> Data {
        var buf = Data([0x00])
        buf.append(deviceId.data(using: .utf8)!)
        buf.append(identityKey)
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
        var buf = "ConstructKT-v1".data(using: .utf8)!
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

        // 1. Basic sanity
        guard treeSize > 0, leafIndex < treeSize,
              rootHash.count == 32,
              proofHashes.allSatisfy({ $0.count == 32 }) else {
            return .failed(.malformedProof)
        }

        // 2. Compute leaf hash
        let lhash = leafHash(deviceId: deviceId, identityKey: identityKey)

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
            // Server key not configured — inclusion proof checks out but STH can't be verified.
            return .failed(.treeHeadKeyMissing)
        }
        guard let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes) else {
            return .failed(.treeHeadKeyMissing)
        }
        let signable = treeHeadSignable(treeSize: treeSize, rootHash: rootHash)
        guard pubKey.isValidSignature(treeHeadSignature, for: signable) else {
            return .failed(.signatureInvalid)
        }

        return .verified
    }
}
