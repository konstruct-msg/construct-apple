//
//  LocalStoreKey.swift
//  Construct Messenger
//
//  The key this device seals what it keeps at rest under.
//  `decisions/macos-store-encrypted-at-rest.md` (variant B)
//

import CryptoKit
import Foundation

/// 256 random bits in the Keychain, this device only, readable after the first unlock. Until
/// 2026-09-30 the per-message storage keys lay in `message_keys.sqlite` next to the ciphertext they
/// open — on macOS, where file protection does nothing, that encryption bought nothing. Sealing
/// them under this key moves the secret out of the container: a copy of the container (a backup,
/// a copied folder, another process of the same user) no longer reads.
///
/// `LocalDataWipe` deletes it first, so whatever the wipe fails to remove is already unreadable.
enum LocalStoreKey {

    static let account = "construct.localStore.key.v1"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SymmetricKey?

    /// The key, minted on first use. `nil` when the Keychain does not answer — before the first
    /// unlock, or a damaged item — and **never a fresh key then**: minting one over an unreadable
    /// item would orphan everything sealed under the existing one (the 2026-08-09 lesson in
    /// `DeviceKeyAvailability`, at the scale of the whole store).
    static func current() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        switch KeychainManager.shared.read(forKey: account) {
        case .found(let data) where data.count == 32:
            cached = SymmetricKey(data: data)
        case .found(let data):
            Log.error("LocalStoreKey: stored key is \(data.count) bytes — not replacing it", category: "Storage")
        case .absent:
            let key = SymmetricKey(size: .bits256)
            guard KeychainManager.shared.saveLocalStoreKey(key.withUnsafeBytes { Data($0) }) else {
                Log.error("LocalStoreKey: could not save a new key", category: "Storage")
                return nil
            }
            cached = key
        case .unreadable(let status):
            Log.error("LocalStoreKey: Keychain unreadable (\(status))", category: "Storage")
        }
        return cached
    }

    static func destroy() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        KeychainManager.shared.deleteLocalStoreKey()
    }
}

/// AES-256-GCM, with the row or file a value belongs to as associated data: a sealed value moved
/// to another row does not open. Format: nonce(12) ‖ ciphertext ‖ tag(16).
enum AtRestSeal {

    static let overhead = 12 + 16

    static func seal(_ plaintext: Data, under key: SymmetricKey, boundTo context: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw MessageStorageCryptoError.invalidCiphertext }
        return combined
    }

    static func open(_ sealed: Data, under key: SymmetricKey, boundTo context: String) throws -> Data {
        guard sealed.count >= overhead else { throw MessageStorageCryptoError.invalidCiphertext }
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }
}
