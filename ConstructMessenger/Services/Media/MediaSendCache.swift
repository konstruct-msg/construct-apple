//
//  MediaSendCache.swift
//  Construct Messenger
//
//  Dedup cache for outgoing media uploads. When the user sends the same binary
//  content more than once within the TTL window, the already-uploaded object
//  (mediaId + URL + AES key) is reused without re-encrypting or re-uploading. This
//  cuts upload traffic, local CPU, and server object duplication while staying E2EE-safe:
//
//    • The AES key lives inside the DR-encrypted message payload → protected on the wire.
//    • Each recipient gets an independent DR envelope even when the mediaId and AES key
//      are identical across messages (different DR chain states).
//    • Dedup is per-sender (random key per content, NOT convergent encryption), so it
//      does not enable the cross-user "confirmation-of-file" attack.
//
//  Persistence (2026-06-15): the cache is persisted in the Keychain
//  (AfterFirstUnlockThisDeviceOnly) so dedup survives app restarts — e.g. re-forwarding
//  the same photo days later reuses one upload. The persisted values include the media
//  AES keys; they are strictly less sensitive than the decrypted media already held in
//  MediaManager's on-disk cache, and ThisDeviceOnly keeps them out of iCloud/backups.
//
//  Cache key: SHA-256 of the plaintext bytes (before AES-GCM encryption) — fixed-length,
//  non-reversible.
//
//  TTL: 6 days. This MUST stay strictly below the media-service retention
//  (`MEDIA_FILE_TTL_SECONDS`, default 7 days), which deletes objects by file mtime from
//  UPLOAD time. A cache hit does NOT touch the server mtime, so a reused mediaId points to
//  an object the server will still delete 7 days after the ORIGINAL upload. Keeping the
//  client TTL < server retention guarantees a hit never returns a dead mediaId. If the
//  server retention changes, change this in lock-step.
//

import CryptoKit
import Foundation
import Security

actor MediaSendCache {
    static let shared = MediaSendCache()
    private init() {}

    private static let keychainKey = "construct.media_send_cache_v1"
    /// Must remain < media-service `MEDIA_FILE_TTL_SECONDS` (7 days). See header.
    private static let ttl: TimeInterval = 6 * 24 * 60 * 60
    private static let maxEntries = 100

    private struct Entry: Codable {
        let result: MediaServiceClient.UploadedMedia
        let createdAt: Date
    }

    // Keyed by hex-encoded SHA-256 of plaintext.
    private var store: [String: Entry] = [:]
    private var didLoad = false

    // MARK: - Public API

    /// Returns a cached upload result for `data` if one exists and is not expired.
    func cachedUpload(for data: Data) -> MediaServiceClient.UploadedMedia? {
        loadIfNeeded()
        let key = plaintextKey(data)
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.createdAt) < Self.ttl else {
            store.removeValue(forKey: key)
            persist()
            return nil
        }
        return entry.result
    }

    /// Stores an upload result so it can be reused for identical plaintext.
    func storeUpload(_ result: MediaServiceClient.UploadedMedia, for data: Data) {
        loadIfNeeded()
        evictExpired()
        if store.count >= Self.maxEntries { evictOldest() }
        store[plaintextKey(data)] = Entry(result: result, createdAt: Date())
        persist()
    }

    /// Clears the entire cache (call on sign-out or memory pressure).
    func clear() {
        store.removeAll()
        didLoad = true
        KeychainManager.shared.deleteData(forKey: Self.keychainKey)
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = KeychainManager.shared.loadData(forKey: Self.keychainKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        // Drop anything already expired on load so we never hand out a dead mediaId.
        let now = Date()
        store = decoded.filter { now.timeIntervalSince($0.value.createdAt) < Self.ttl }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        _ = KeychainManager.shared.saveData(
            data, forKey: Self.keychainKey,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

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
