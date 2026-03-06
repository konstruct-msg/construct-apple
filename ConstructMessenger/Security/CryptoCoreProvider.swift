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

    func loadCore() -> (core: ClassicCryptoCore?, wasRestoredFromKeychain: Bool) {
        do {
            if let savedKeysJson = keychain.loadPrivateKeysJson() {
                Log.info("🔑 Found existing keys in Keychain, restoring CryptoCore...", category: "CryptoManager")
                let core = try createCryptoCoreFromKeysJson(keysJson: savedKeysJson)

                // Restore persisted OTPKs so the core knows about the keys already on the server.
                // Without this, any initiator using a server OTPK would trigger an AEAD failure
                // because the restored core's OTPK store is empty.
                if let otpksJson = keychain.loadOtpksJson() {
                    do {
                        try core.importOneTimePrekeysJson(json: otpksJson)
                        let count = core.oneTimePrekeyCount()
                        Log.info("✅ Restored \(count) OTPKs from Keychain", category: "CryptoManager")
                    } catch {
                        Log.error("⚠️ Failed to import persisted OTPKs — fallback will replace server keys: \(error)", category: "CryptoManager")
                    }
                } else {
                    Log.info("ℹ️ No persisted OTPKs found in Keychain — fallback will replace server keys on startup", category: "CryptoManager")
                }

                Log.info("✅ CryptoCore restored from saved keys!", category: "CryptoManager")
                return (core, true)
            }

            Log.info("🆕 No saved keys found, CryptoCore not initialized yet", category: "CryptoManager")
            return (nil, false)
        } catch let error as CryptoError {
            Log.fault("❌ Failed to restore UniFFI CryptoCore: \(error)", category: "CryptoManager")
            return (nil, false)
        } catch {
            Log.fault("❌ Unexpected error restoring CryptoCore: \(error)", category: "CryptoManager")
            return (nil, false)
        }
    }
}
