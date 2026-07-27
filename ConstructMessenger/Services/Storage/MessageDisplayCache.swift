//
//  MessageDisplayCache.swift
//  Construct Messenger
//

import Foundation
import CoreData

/// In-memory cache of decrypted message **payload bytes** (CTM1 envelope or legacy UTF-8).
///
/// NSCache is thread-safe; `store` and `payloadData(for:)` may be called from any thread.
/// On cache miss, bytes are recovered from `MessageKeyStore` + `MessageStorageCrypto`,
/// or from legacy `decryptedContent` for unmigrated rows.
///
/// UI text edge: `plaintext(for:)` decodes via `LocalMessagePayload` (E1/E2).
final class MessageDisplayCache {

    static let shared = MessageDisplayCache()

    private let cache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 500
    }

    // MARK: - Write

    func store(messageId: String, plaintextData: Data) {
        cache.setObject(plaintextData as NSData, forKey: messageId as NSString)
    }

    /// Convenience for legacy callers that only have a String.
    func store(messageId: String, plaintext: String) {
        store(messageId: messageId, plaintextData: Data(plaintext.utf8))
    }

    func evict(messageId: String) {
        cache.removeObject(forKey: messageId as NSString)
    }

    func evictAll() {
        cache.removeAllObjects()
    }

    // MARK: - Read

    /// Raw decrypted payload bytes (CTM1 or legacy UTF-8). Empty on failure.
    func payloadData(for message: Message) -> Data {
        let id = message.id

        if let cached = cache.object(forKey: id as NSString) {
            return cached as Data
        }

        // Legacy unmigrated row — plaintext still in decryptedContent.
        if let legacy = message.decryptedContent {
            let data = Data(legacy.utf8)
            cache.setObject(data as NSData, forKey: id as NSString)
            return data
        }

        let encrypted = message.encryptedContent
        guard let keyRef = message.contentKeyRef,
              let key = MessageKeyStore.shared.fetch(messageId: keyRef),
              !encrypted.isEmpty,
              let plainData = try? MessageStorageCrypto.decrypt(ciphertext: encrypted, key: key)
        else {
            return Data()
        }

        cache.setObject(plainData as NSData, forKey: id as NSString)
        return plainData
    }

    /// Decoded local payload (media album / text / legacy JSON).
    func payload(for message: Message) -> LocalMessagePayload {
        LocalMessagePayload.decode(payloadData(for: message))
    }

    /// Display string for text bubbles and dual-read parsers.
    /// Media CTM1 rehydrates to legacy media JSON only at this edge (not re-stored).
    func plaintext(for message: Message) -> String {
        payload(for: message).displayString
    }
}
