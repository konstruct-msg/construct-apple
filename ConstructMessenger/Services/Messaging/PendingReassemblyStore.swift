//
//  PendingReassemblyStore.swift
//  Construct Messenger
//
//  Durable home for half-arrived multi-chunk messages.
//
//  Why this has to exist at all: a chunk is decrypted the moment it arrives, which consumes its
//  ratchet key — `skipped_message_keys.remove(...)` in the core, and keys are only kept for
//  messages that were *skipped*, never for ones consumed in order. So a redelivered chunk cannot
//  be decrypted a second time after a restart. Forward secrecy is working as designed; the
//  consequence is that the server cannot help us recover a partial message. Either the decrypted
//  bytes survive the restart here, or the message is gone.
//
//  This store is the single source of truth for partial reassembly — there is no separate
//  in-memory pending map. Two stores of one fact is the defect this codebase has spent a week
//  removing; `entries` below is a cache of this file tree, never a second opinion about it.
//
//  At rest: one directory per pending message, one file per chunk, each encrypted with
//  `MessageStorageCrypto` under a store-wide key held in the Keychain as
//  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — reassembly resumes during a background
//  push decrypt, so `WhenUnlocked*` would silently break exactly the case this exists for.
//  One file per chunk rather than one growing blob: rewriting the whole message on every chunk
//  is quadratic, and a 256-chunk file send would write ~128 MB to disk to deliver 1 MB.
//
//  See decisions/durable-chunk-reassembly.md.
//

import Foundation

struct PendingReassembly {
    let messageId: UUID
    let totalChunks: UInt16
    let plaintextLength: Int
    let contentType: UInt8
    var receivedChunks: [UInt16: Data]
    let startedAt: Date
    /// Envelope ids that carried the chunks. Held so every one of them can be marked processed
    /// once the bytes are durable — an intermediate envelope that is never marked is what made
    /// the same ids loop through redelivery.
    var envelopeIds: [String]

    var isComplete: Bool { receivedChunks.count == Int(totalChunks) }

    var missingIndices: [UInt16] {
        (0..<totalChunks).filter { receivedChunks[$0] == nil }
    }

    /// Chunks joined in index order, trimmed to the declared plaintext length.
    /// nil when a chunk is missing or the declared length overruns what arrived.
    func assembled() -> Data? {
        var out = Data()
        for index in 0..<totalChunks {
            guard let chunk = receivedChunks[index] else { return nil }
            out.append(chunk)
        }
        guard plaintextLength <= out.count else { return nil }
        return Data(out.prefix(plaintextLength))
    }
}

final class PendingReassemblyStore {

    static let shared = PendingReassemblyStore()

    /// How long a partial message is kept. Deliberately far longer than the old 60 s in-memory
    /// sweep: that number bounded memory, this one bounds *recoverability*, and the case this
    /// store exists for is "the app was killed and comes back later". A minute would have thrown
    /// away the partial before the relaunch it was written for.
    static let retention: TimeInterval = 24 * 60 * 60

    private let queue = DispatchQueue(label: "construct.PendingReassemblyStore")
    private var entries: [UUID: PendingReassembly] = [:]
    private var loadedFromDisk = false

    private static let keychainAccount = "construct.reassembly_store_key"

    private init() {}

    // MARK: - API

    /// Record one chunk. Returns the entry once every chunk is present, nil while it is still
    /// incomplete. The bytes are on disk before this returns, so the caller may safely treat the
    /// envelope as handled.
    func put(
        messageId: UUID,
        chunkIndex: UInt16,
        totalChunks: UInt16,
        plaintextLength: Int,
        contentType: UInt8,
        payload: Data,
        envelopeId: String,
        now: Date = Date()
    ) -> PendingReassembly? {
        queue.sync {
            loadIfNeeded()
            sweep(now: now)

            var entry = entries[messageId] ?? PendingReassembly(
                messageId: messageId,
                totalChunks: totalChunks,
                plaintextLength: plaintextLength,
                contentType: contentType,
                receivedChunks: [:],
                startedAt: now,
                envelopeIds: []
            )
            entry.receivedChunks[chunkIndex] = payload
            if !entry.envelopeIds.contains(envelopeId) { entry.envelopeIds.append(envelopeId) }
            entries[messageId] = entry

            persist(entry, chunkIndex: chunkIndex, payload: payload)

            guard entry.isComplete else { return nil }
            return entry
        }
    }

    /// Drop a completed (or abandoned) reassembly and its files.
    func remove(messageId: UUID) {
        queue.sync {
            entries.removeValue(forKey: messageId)
            try? FileManager.default.removeItem(at: directory(for: messageId))
        }
    }

    /// Expire anything past `retention`, reporting each as a real loss. Call on any decrypted
    /// message so a stalled reassembly surfaces while ordinary traffic keeps flowing.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> [PendingReassembly] {
        queue.sync {
            loadIfNeeded()
            return sweep(now: now)
        }
    }

    /// Test/diagnostic view of what is currently held.
    func pendingCount() -> Int {
        queue.sync {
            loadIfNeeded()
            return entries.count
        }
    }

    /// Drop the in-memory cache so the next access reads the file tree again — what a relaunch
    /// does. The seam exists because the property that matters (a partial message survives the
    /// process) cannot be observed any other way from a test.
    func forgetInMemoryStateForTesting() {
        queue.sync {
            entries.removeAll()
            loadedFromDisk = false
        }
    }

    // MARK: - Expiry

    @discardableResult
    private func sweep(now: Date) -> [PendingReassembly] {
        let expired = entries.values.filter { now.timeIntervalSince($0.startedAt) > Self.retention }
        guard !expired.isEmpty else { return [] }

        for entry in expired {
            Log.error(
                "Chunked message LOST for \(entry.messageId.uuidString.prefix(8))… — \(entry.receivedChunks.count)/\(entry.totalChunks) chunks after \(Int(now.timeIntervalSince(entry.startedAt)))s, missing indices \(entry.missingIndices.prefix(16).map(String.init).joined(separator: ",")) — not recoverable (ratchet keys for the missing chunks are consumed)",
                category: "ChunkedDelivery"
            )
            PerformanceMetrics.shared.record(
                .chunkReassemblyExpired,
                label: String(entry.messageId.uuidString.prefix(8))
            )
            entries.removeValue(forKey: entry.messageId)
            try? FileManager.default.removeItem(at: directory(for: entry.messageId))
        }
        return expired
    }

    // MARK: - Disk

    private var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PendingReassembly", isDirectory: true)
    }

    private func directory(for messageId: UUID) -> URL {
        root.appendingPathComponent(messageId.uuidString, isDirectory: true)
    }

    /// One `meta` file plus one file per chunk. `meta` is rewritten on every chunk (it is tens of
    /// bytes and carries the growing envelope-id list); chunk files are written once.
    private func persist(_ entry: PendingReassembly, chunkIndex: UInt16, payload: Data) {
        guard let key = storeKey() else {
            Log.error("Reassembly store: no key — partial message will not survive a restart", category: "ChunkedDelivery")
            return
        }
        let dir = directory(for: entry.messageId)
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let meta = Meta(
                totalChunks: entry.totalChunks,
                plaintextLength: entry.plaintextLength,
                contentType: entry.contentType,
                startedAt: entry.startedAt.timeIntervalSince1970,
                envelopeIds: entry.envelopeIds
            )
            let metaPlain = try JSONEncoder().encode(meta)
            try MessageStorageCrypto.encrypt(plaintext: metaPlain, key: key)
                .write(to: dir.appendingPathComponent("meta"), options: .atomic)
            try MessageStorageCrypto.encrypt(plaintext: payload, key: key)
                .write(to: dir.appendingPathComponent("\(chunkIndex)"), options: .atomic)
        } catch {
            Log.error("Reassembly store: failed to persist chunk \(chunkIndex) of \(entry.messageId.uuidString.prefix(8))…: \(error)", category: "ChunkedDelivery")
        }
    }

    private func loadIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let key = storeKey(),
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }

        for dir in dirs {
            guard let messageId = UUID(uuidString: dir.lastPathComponent) else { continue }
            guard let metaCipher = try? Data(contentsOf: dir.appendingPathComponent("meta")),
                  let metaPlain = try? MessageStorageCrypto.decrypt(ciphertext: metaCipher, key: key),
                  let meta = try? JSONDecoder().decode(Meta.self, from: metaPlain)
            else {
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            var chunks: [UInt16: Data] = [:]
            for index in 0..<meta.totalChunks {
                guard let cipher = try? Data(contentsOf: dir.appendingPathComponent("\(index)")),
                      let plain = try? MessageStorageCrypto.decrypt(ciphertext: cipher, key: key)
                else { continue }
                chunks[index] = plain
            }
            entries[messageId] = PendingReassembly(
                messageId: messageId,
                totalChunks: meta.totalChunks,
                plaintextLength: meta.plaintextLength,
                contentType: meta.contentType,
                receivedChunks: chunks,
                startedAt: Date(timeIntervalSince1970: meta.startedAt),
                envelopeIds: meta.envelopeIds
            )
        }
        if !entries.isEmpty {
            Log.info("Reassembly store: restored \(entries.count) partial message(s) from disk", category: "ChunkedDelivery")
        }
    }

    private struct Meta: Codable {
        let totalChunks: UInt16
        let plaintextLength: Int
        let contentType: UInt8
        let startedAt: TimeInterval
        let envelopeIds: [String]
    }

    // MARK: - Key

    private func storeKey() -> Data? {
        if let existing = KeychainManager.shared.loadReassemblyStoreKey() { return existing }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        KeychainManager.shared.saveReassemblyStoreKey(key)
        return KeychainManager.shared.loadReassemblyStoreKey()
    }
}
