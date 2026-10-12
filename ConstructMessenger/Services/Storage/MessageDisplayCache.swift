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

    private let cache = NSCache<NSString, WipedOnRelease>()

    private init() {
        // 500 messages: a body, a transcript and a quote each.
        cache.countLimit = 1_500
    }

    // MARK: - Write

    func store(messageId: String, plaintextData: Data) {
        cache.setObject(WipedOnRelease(plaintextData), forKey: messageId as NSString)
    }

    /// Convenience for legacy callers that only have a String.
    func store(messageId: String, plaintext: String) {
        store(messageId: messageId, plaintextData: Data(plaintext.utf8))
    }

    func evict(messageId: String) {
        cache.removeObject(forKey: messageId as NSString)
        for field in SealedText.allCases {
            cache.removeObject(forKey: field.key(messageId) as NSString)
        }
    }

    func evictAll() {
        cache.removeAllObjects()
    }

    /// The cached bytes for `messageId`, if held — for tests of `UnsealedMemory`.
    func cachedPayload(messageId: String) -> Data? {
        cache.object(forKey: messageId as NSString)?.data
    }

    // MARK: - Read

    /// Raw decrypted payload bytes (CTM1 or legacy UTF-8). Empty on failure.
    func payloadData(for message: Message) -> Data {
        let id = message.id

        if let cached = cache.object(forKey: id as NSString) {
            return cached.data
        }

        // Legacy unmigrated row — plaintext still in decryptedContent.
        if let legacy = message.decryptedContent {
            let data = Data(legacy.utf8)
            cache.setObject(WipedOnRelease(data), forKey: id as NSString)
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

        cache.setObject(WipedOnRelease(plainData), forKey: id as NSString)
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

    // MARK: - By id

    /// The two texts a row carries beside its body, sealed in the store like it.
    enum SealedText: CaseIterable {
        case transcript, replyQuote

        fileprivate func key(_ messageId: String) -> String {
            switch self {
            case .transcript: "\(messageId)#transcript"
            case .replyQuote: "\(messageId)#quote"
            }
        }
    }

    /// The payload of message `messageId` — what a transcript row shows, read when shown rather
    /// than carried in the row, so the text stays in this cache, which `UnsealedMemory` empties
    /// and zeroes. A miss reads the message from `store` and caches its body and both texts.
    func payload(messageId: String, store: any MessageStore = LocalRepositories.messages) -> LocalMessagePayload {
        LocalMessagePayload.decode(payloadData(messageId: messageId, store: store))
    }

    /// The raw payload bytes of message `messageId` (CTM1 or legacy UTF-8); empty when there is no
    /// such message or it has no body. A miss reads as `payload` does.
    func payloadData(messageId: String, store: any MessageStore = LocalRepositories.messages) -> Data {
        if let cached = cache.object(forKey: messageId as NSString) {
            return cached.data
        }
        guard let record = try? store.message(messageId) else { return Data() }
        hold(record)
        return record.body
    }

    /// `field` of message `messageId`, nil when it has none. A miss reads as `payload` does.
    func text(_ field: SealedText, messageId: String, store: any MessageStore = LocalRepositories.messages) -> String? {
        if let cached = cache.object(forKey: field.key(messageId) as NSString) {
            return Self.unmark(cached.data)
        }
        guard let record = try? store.message(messageId) else { return nil }
        hold(record)
        return field == .transcript ? record.transcript : record.replyQuote
    }

    /// What a transcript read already decrypted, so the rows it lists open without a second read.
    func hold(_ record: MessageRecord) {
        store(messageId: record.id, plaintextData: record.body)
        cache.setObject(WipedOnRelease(Self.mark(record.transcript)), forKey: SealedText.transcript.key(record.id) as NSString)
        cache.setObject(WipedOnRelease(Self.mark(record.replyQuote)), forKey: SealedText.replyQuote.key(record.id) as NSString)
    }

    /// A held absence is a value too: one leading byte says whether a text follows, so a row with
    /// no quote is not read from the store again on every render.
    private static func mark(_ text: String?) -> Data {
        guard let text else { return Data([0]) }
        return Data([1]) + Data(text.utf8)
    }

    private static func unmark(_ data: Data) -> String? {
        guard data.first == 1 else { return nil }
        return String(decoding: data.dropFirst(), as: UTF8.self)
    }
}

/// A decrypted payload held by the cache, zeroed when the cache lets go of it — on eviction, on
/// `evictAll` (which `UnsealedMemory` calls when the app leaves the screen) and under memory
/// pressure. `NSCache` frees an `NSData` without zeroing it, which left message text readable in
/// released memory. Only this copy is wiped: a reader that took the bytes keeps its own.
final class WipedOnRelease {
    private(set) var data: Data

    init(_ data: Data) {
        self.data = data
    }

    deinit {
        Self.wipe(&data)
    }

    /// Zeroes `data` in place with `memset_s`, which the compiler may not drop as a dead store.
    static func wipe(_ data: inout Data) {
        let count = data.count
        data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = memset_s(base, count, 0, count)
        }
    }
}
