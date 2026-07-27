//
//  IdentityFingerprint.swift
//  Construct Messenger
//
//  Short comparable fingerprint of an identity public key — the user-facing
//  external identity form (plan thread 5.3). UUID stays internal for sessions.
//

import Foundation
import CryptoKit

/// Derives a short, human-comparable fingerprint from an Ed25519 (or future) identity public key.
///
/// Algorithm:
/// 1. SHA-256(identity_public_key)
/// 2. Take first 8 bytes
/// 3. Format as uppercase hex groups of 4: `A1B2 C3D4 E5F6 G7H8`
///
/// This is **not** the two-party Safety Number (that needs both device ids).
/// It is a single-key label for TOFU display and out-of-band comparison of "who is this key".
enum IdentityFingerprint {

    /// Number of raw hash bytes used (8 → 16 hex chars → 4×4 groups).
    static let byteCount = 8

    /// Compact fingerprint, or `nil` if the key is empty.
    static func short(from identityPublicKey: Data) -> String? {
        guard !identityPublicKey.isEmpty else { return nil }
        let digest = SHA256.hash(data: identityPublicKey)
        let prefix = Array(digest.prefix(byteCount))
        let hex = prefix.map { String(format: "%02X", $0) }.joined()
        // Group as XXXX XXXX XXXX XXXX
        var groups: [String] = []
        groups.reserveCapacity(4)
        var i = hex.startIndex
        while i < hex.endIndex {
            let end = hex.index(i, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[i..<end]))
            i = end
        }
        return groups.joined(separator: " ")
    }

    /// Same as `short(from:)` for `[UInt8]` keys from UniFFI / Rust.
    static func short(from identityPublicKey: [UInt8]) -> String? {
        short(from: Data(identityPublicKey))
    }

    /// Compact form without spaces (for logs / copy).
    static func compact(from identityPublicKey: Data) -> String? {
        short(from: identityPublicKey)?.replacingOccurrences(of: " ", with: "")
    }
}
