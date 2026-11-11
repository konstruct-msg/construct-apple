//
//  DisplayNameGenerator.swift
//  Construct Messenger
//
//  Generates human-readable anonymous names for privacy
//  Uses deterministic adjective+animal based on userId hash
//

import Foundation
import CryptoKit

/// The name a person who chose none is called by: an adjective and an animal, or one time in five
/// an IT noun ("silent dolphin"), picked by the SHA-256 of the account id. The rule is the core's
/// (construct-rules `names`), one for every client: the word lists and the index lived here, on
/// Android and in construct-client until 2026-11-10 (`decisions/client-rules-shared-in-rust.md`).
struct DisplayNameGenerator {

    /// The generated name of `userId`, lower case.
    static func generate(from userId: String) -> String {
        generatedName(userId: userId)
    }

    /// Whether `name` is only the name generated from `userId` — something any client computes
    /// for itself, so it says nothing about what the person chose to be called. Any case, trimmed.
    static func isGenerated(_ name: String, for userId: String) -> Bool {
        isGeneratedName(name: name, userId: userId)
    }

    /// Generate short ID (first 6 chars of hash) as fallback
    /// - Parameter userId: User's UUID
    /// - Returns: Short hex like "a3f8c2"
    static func generateShortId(from userId: String) -> String {
        let hash = SHA256.hash(data: Data(userId.utf8))
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return String(hashHex.prefix(6))
    }
}
