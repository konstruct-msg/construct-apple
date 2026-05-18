//
//  MediaSendCache.swift
//  Construct Messenger
//
//  In-memory cache for outgoing media uploads. When the user sends the same
//  binary content more than once within the TTL window, the already-uploaded
//  object (mediaId + URL + AES key) is reused without re-encrypting or
//  re-uploading. This reduces upload traffic, local CPU use, and server object
//  duplication while remaining E2EE-safe:
//
//    • The AES key lives inside the DR-encrypted message payload → protected.
//    • Each recipient gets an independent DR envelope even when the mediaId
//      and AES key are identical across messages (different DR chain states).
//    • The cache is purely in-memory and scoped to one app session — no
//      sensitive data is persisted to disk by this layer.
//
//  Cache key: SHA-256 of the plaintext bytes (before AES-GCM encryption).
//  This is a fixed-length, non-reversible identifier — looking up a hit
//  never reveals the plaintext to any other caller.
//
//  Limits:
//    TTL     30 minutes   — conservative; server keeps objects much longer
//    MaxEntries 20        — prevents accumulation for large-file senders
//

import CryptoKit
import Foundation

actor MediaSendCache {
    static let shared = MediaSendCache()
    private init() {}

    private static let ttl: TimeInterval = 30 * 60
    private static let maxEntries = 20

    private struct Entry {
        let result: MediaServiceClient.UploadedMedia
        let createdAt: Date
    }

    // Keyed by hex-encoded SHA-256 of plaintext
    private var store: [String: Entry] = [:]

    // MARK: - Public API

    /// Returns a cached upload result for `data` if one exists and is not expired.
    func cachedUpload(for data: Data) -> MediaServiceClient.UploadedMedia? {
        let key = plaintextKey(data)
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.createdAt) < Self.ttl else {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.result
    }

    /// Stores an upload result so it can be reused for identical plaintext.
    func storeUpload(_ result: MediaServiceClient.UploadedMedia, for data: Data) {
        evictExpired()
        if store.count >= Self.maxEntries { evictOldest() }
        store[plaintextKey(data)] = Entry(result: result, createdAt: Date())
    }

    /// Clears the entire cache (call on sign-out or memory pressure).
    func clear() { store.removeAll() }

    // MARK: - Private helpers

    private func plaintextKey(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func evictExpired() {
        let now = Date()
        store = store.filter { now.timeIntervalSince($0.value.createdAt) < Self.ttl }
    }

    private func evictOldest() {
        guard let oldest = store.min(by: { $0.value.createdAt < $1.value.createdAt }) else { return }
        store.removeValue(forKey: oldest.key)
    }
}
