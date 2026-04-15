//
//  TokenWalletService.swift
//  Construct Messenger
//
//  Manages the STEALTH per-message token wallet.
//  Tokens are UUIDs stored as JSON in the Keychain.
//  Minted in the background during maintenance; consumed 1-per-message in per-message stealth mode.
//

import Foundation
import Observation

@Observable
@MainActor
final class TokenWalletService {
    static let shared = TokenWalletService()

    private static let keychainKey = "stealth_token_wallet_v1"
    private static let maxBalance = 500

    private(set) var balance: Int = 0

    private init() {
        balance = loadTokens().count
    }

    // MARK: - Public API

    /// Mint up to `count` new tokens (capped at maxBalance total).
    func mintTokens(count: Int) {
        var tokens = loadTokens()
        let canAdd = min(count, Self.maxBalance - tokens.count)
        guard canAdd > 0 else { return }
        for _ in 0..<canAdd {
            tokens.append(UUID().uuidString)
        }
        saveTokens(tokens)
        balance = tokens.count
        Log.info("🪙 TokenWallet: minted \(canAdd) tokens (balance=\(balance))", category: "TokenWallet")
    }

    /// Consume one token. Returns false if the wallet is empty.
    @discardableResult
    func consumeToken() -> Bool {
        var tokens = loadTokens()
        guard !tokens.isEmpty else {
            Log.debug("🪙 TokenWallet: empty — cannot consume", category: "TokenWallet")
            return false
        }
        tokens.removeFirst()
        saveTokens(tokens)
        balance = tokens.count
        return true
    }

    // MARK: - Storage

    private func loadTokens() -> [String] {
        guard
            let data = KeychainManager.shared.loadRawData(forKey: Self.keychainKey),
            let tokens = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return tokens
    }

    private func saveTokens(_ tokens: [String]) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        KeychainManager.shared.saveRawData(data, forKey: Self.keychainKey)
    }
}
