//
//  MessageDisplayCache.swift
//  Construct Messenger
//

import Foundation
import CoreData

/// In-memory cache of decrypted message text.
///
/// NSCache is thread-safe; `store` and `plaintext(for:)` may be called from any thread.
/// On cache miss, plaintext is recovered synchronously from `MessageKeyStore` +
/// `MessageStorageCrypto`, or from legacy `decryptedContent` for unmigrated rows.
final class MessageDisplayCache {

    static let shared = MessageDisplayCache()

    private let cache = NSCache<NSString, NSString>()

    private init() {
        cache.countLimit = 500
    }

    // MARK: - Write

    func store(messageId: String, plaintext: String) {
        cache.setObject(plaintext as NSString, forKey: messageId as NSString)
    }

    func evict(messageId: String) {
        cache.removeObject(forKey: messageId as NSString)
    }

    func evictAll() {
        cache.removeAllObjects()
    }

    // MARK: - Read

    /// Return decrypted text for the given message.
    ///
    /// Resolution order:
    /// 1. In-memory cache (O(1), no I/O)
    /// 2. Legacy `decryptedContent` field (unmigrated rows)
    /// 3. On-demand decrypt via `MessageKeyStore` + `MessageStorageCrypto`
    func plaintext(for message: Message) -> String {
        let id = message.id

        if let cached = cache.object(forKey: id as NSString) {
            return cached as String
        }

        // Legacy unmigrated row — still has plaintext in decryptedContent.
        if let legacy = message.decryptedContent {
            cache.setObject(legacy as NSString, forKey: id as NSString)
            return legacy
        }

        // Migrated row — decrypt on demand.
        let encrypted = message.encryptedContent
        guard let keyRef = message.contentKeyRef,
              let key = MessageKeyStore.shared.fetch(messageId: keyRef),
              !encrypted.isEmpty,
              let plainData = try? MessageStorageCrypto.decrypt(ciphertext: encrypted, key: key),
              let text = String(data: plainData, encoding: .utf8)
        else {
            return ""
        }

        cache.setObject(text as NSString, forKey: id as NSString)
        return text
    }
}
