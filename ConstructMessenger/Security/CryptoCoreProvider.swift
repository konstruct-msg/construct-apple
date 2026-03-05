//
//  CryptoCoreProvider.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation

final class CryptoCoreProvider {
    private let keychain: KeychainManager

    init(keychain: KeychainManager = .shared) {
        self.keychain = keychain
    }

    func loadCore() -> ClassicCryptoCore? {
        do {
            if let savedKeysJson = keychain.loadPrivateKeysJson() {
                Log.info("🔑 Found existing keys in Keychain, restoring CryptoCore...", category: "CryptoManager")
                let core = try createCryptoCoreFromKeysJson(keysJson: savedKeysJson)
                Log.info("✅ CryptoCore restored from saved keys!", category: "CryptoManager")
                return core
            }

            Log.info("🆕 No saved keys found, CryptoCore not initialized yet", category: "CryptoManager")
            return nil
        } catch let error as CryptoError {
            Log.fault("❌ Failed to restore UniFFI CryptoCore: \(error)", category: "CryptoManager")
            return nil
        } catch {
            Log.fault("❌ Unexpected error restoring CryptoCore: \(error)", category: "CryptoManager")
            return nil
        }
    }
}
