//
//  TokenWalletService.swift
//  Construct Messenger
//
//  Manages the STEALTH token wallet (Privacy Pass blind tokens).
//  Pure wallet: deposit, unconditional consume, balance.
//
//  All policy decisions (when to use sealed sender, when to spend a token)
//  live in StealthPolicy.
//

import Foundation
import Observation

/// A finalized Privacy Pass blind token. The `token` bytes are the HKDF output
/// from the OPRF evaluation; `nonce` is retained for future revocation proof.
struct BlindToken: Codable, Sendable {
    /// Original 32-byte random nonce used during blinding.
    let nonce: Data
    /// 32-byte finalized token: HKDF(k·T) derived in Rust core.
    let token: Data
}

@Observable
@MainActor
final class TokenWalletService {
    static let shared = TokenWalletService()

    private static let keychainKey = "stealth_token_wallet_v2"
    private static let maxBalance = 500

    private(set) var balance: Int = 0

    private init() {
        balance = loadTokens().count
    }

    // MARK: - Public API

    /// Deposit server-issued blind tokens (from BlindTokenService).
    func deposit(_ tokens: [BlindToken]) {
        var existing = loadTokens()
        let canAdd = min(tokens.count, Self.maxBalance - existing.count)
        guard canAdd > 0 else { return }
        existing.append(contentsOf: tokens.prefix(canAdd))
        saveTokens(existing)
        balance = existing.count
        Log.info("TokenWallet: deposited \(canAdd) blind tokens (balance=\(balance))", category: "TokenWallet")
    }

    /// Consume one token unconditionally.
    /// StealthPolicy decides *when* to call this based on per-stream / per-message rules.
    @discardableResult
    func consumeToken() -> BlindToken? {
        var tokens = loadTokens()
        guard !tokens.isEmpty else {
            Log.debug("TokenWallet: empty — cannot consume", category: "TokenWallet")
            return nil
        }
        let token = tokens.removeFirst()
        saveTokens(tokens)
        balance = tokens.count
        return token
    }

    /// Returns true if at least one token is available.
    var hasToken: Bool { balance > 0 }

    // MARK: - Storage for tokens

    private func loadTokens() -> [BlindToken] {
        guard
            let data = KeychainManager.shared.loadRawData(forKey: Self.keychainKey),
            let tokens = try? JSONDecoder().decode([BlindToken].self, from: data)
        else { return [] }
        return tokens
    }

    private func saveTokens(_ tokens: [BlindToken]) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        KeychainManager.shared.saveRawData(data, forKey: Self.keychainKey)
    }
}
