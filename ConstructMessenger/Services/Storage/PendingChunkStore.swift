//
//  PendingChunkStore.swift
//  Construct Messenger
//
//  Chunks of a message that has not finished arriving, kept across a restart: a chunk's ratchet
//  key is spent the moment it is decrypted, so if the bytes are lost the message is gone
//  (decisions/durable-chunk-reassembly.md). Behind the storage seam with the operations
//  `LocalStore` has — `add_pending_chunk`, `pending_chunks`, `pending_chunk_count`,
//  `pending_chunk_messages`, `delete_pending_chunks` (construct-core 0.40.0, `pending_chunks`).
//
//  A message is one sender's: chunks are keyed by sender and message id together, so a peer that
//  learned or guessed another sender's message id cannot add bytes to that sender's message.
//

import Foundation
import Security

struct PendingChunkRecord: Equatable, Sendable {
    let senderId: String
    /// Lowercase UUID text, as the KNST header names it.
    let messageId: String
    let chunkIndex: UInt16
    let totalChunks: UInt16
    let plaintextLength: Int
    let contentType: UInt8
    let payload: Data
    let receivedAt: Date
}

struct PendingChunkMessage: Equatable, Hashable, Sendable {
    let senderId: String
    let messageId: String
}

protocol PendingChunkStore: Sendable {
    /// Holds `chunk`. A redelivered chunk keeps the copy already held. Returns whether it was new.
    @discardableResult
    func add(_ chunk: PendingChunkRecord) throws -> Bool
    /// One sender's message, by chunk index.
    func chunks(senderId: String, messageId: String) throws -> [PendingChunkRecord]
    func count(senderId: String, messageId: String) throws -> Int
    /// Every message with chunks held, by its first chunk's arrival.
    func messages() throws -> [PendingChunkMessage]
    func delete(senderId: String, messageId: String) throws
}

/// The layout this app has written since 2026-08-03, kept so a partial message on disk at the
/// update still completes: one directory per message (its UUID), a `meta` file and one file per
/// chunk, each sealed with `MessageStorageCrypto` under a store key in the Keychain
/// (`AfterFirstUnlock` — reassembly resumes during a push-woken decrypt). One file per chunk
/// rather than one growing blob: rewriting the message on every chunk is quadratic.
///
/// `meta` names the sender since 2026-10-11. A directory written before has none and belongs to
/// the first sender that adds to it.
final class FilePendingChunkStore: PendingChunkStore, @unchecked Sendable {

    private let root: URL
    private let lock = NSLock()

    init(root: URL = FilePendingChunkStore.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingReassembly", isDirectory: true)
    }

    struct Unavailable: Error {}

    func add(_ chunk: PendingChunkRecord) throws -> Bool {
        try locked {
            guard let dir = directory(for: chunk.messageId) else { throw Unavailable() }
            let key = try storeKey()
            var meta = try readMeta(in: dir, key: key)
            if let held = meta, let owner = held.senderId, owner != chunk.senderId { return false }
            let chunkFile = dir.appendingPathComponent("\(chunk.chunkIndex)")
            if meta != nil, FileManager.default.fileExists(atPath: chunkFile.path) { return false }

            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            if meta == nil || meta?.senderId == nil {
                meta = Meta(
                    totalChunks: meta?.totalChunks ?? chunk.totalChunks,
                    plaintextLength: meta?.plaintextLength ?? chunk.plaintextLength,
                    contentType: meta?.contentType ?? chunk.contentType,
                    startedAt: meta?.startedAt ?? chunk.receivedAt.timeIntervalSince1970,
                    envelopeIds: meta?.envelopeIds ?? [],
                    senderId: chunk.senderId
                )
                try MessageStorageCrypto.encrypt(plaintext: JSONEncoder().encode(meta), key: key)
                    .write(to: dir.appendingPathComponent("meta"), options: .atomic)
            }
            try MessageStorageCrypto.encrypt(plaintext: chunk.payload, key: key)
                .write(to: chunkFile, options: .atomic)
            return true
        }
    }

    func chunks(senderId: String, messageId: String) throws -> [PendingChunkRecord] {
        try locked {
            guard let dir = directory(for: messageId) else { return [] }
            let key = try storeKey()
            guard let meta = try readMeta(in: dir, key: key), meta.belongs(to: senderId) else { return [] }
            return (0..<meta.totalChunks).compactMap { index in
                guard let sealed = try? Data(contentsOf: dir.appendingPathComponent("\(index)")),
                      let payload = try? MessageStorageCrypto.decrypt(ciphertext: sealed, key: key)
                else { return nil }
                return PendingChunkRecord(
                    senderId: senderId, messageId: messageId.lowercased(), chunkIndex: index,
                    totalChunks: meta.totalChunks, plaintextLength: meta.plaintextLength,
                    contentType: meta.contentType, payload: payload,
                    receivedAt: Date(timeIntervalSince1970: meta.startedAt)
                )
            }
        }
    }

    func count(senderId: String, messageId: String) throws -> Int {
        try locked {
            guard let dir = directory(for: messageId) else { return 0 }
            guard let meta = try readMeta(in: dir, key: storeKey()), meta.belongs(to: senderId) else { return 0 }
            return (0..<meta.totalChunks).filter {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0)").path)
            }.count
        }
    }

    func messages() throws -> [PendingChunkMessage] {
        try locked {
            guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                return []
            }
            let key = try storeKey()
            var held: [(PendingChunkMessage, TimeInterval)] = []
            for dir in dirs {
                guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
                guard let meta = try? readMeta(in: dir, key: key) else {
                    // A directory whose meta does not open holds nothing anyone can read back.
                    try? FileManager.default.removeItem(at: dir)
                    continue
                }
                held.append((
                    PendingChunkMessage(senderId: meta.senderId ?? "", messageId: id.uuidString.lowercased()),
                    meta.startedAt
                ))
            }
            return held.sorted { $0.1 < $1.1 }.map(\.0)
        }
    }

    func delete(senderId: String, messageId: String) throws {
        try locked {
            guard let dir = directory(for: messageId) else { return }
            if let meta = try? readMeta(in: dir, key: storeKey()), !meta.belongs(to: senderId) { return }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Layout

    private struct Meta: Codable {
        let totalChunks: UInt16
        let plaintextLength: Int
        let contentType: UInt8
        let startedAt: TimeInterval
        /// Written until 2026-10-11 and read by nothing; kept so older metas decode.
        let envelopeIds: [String]
        /// Nil in a directory written before 2026-10-11.
        let senderId: String?

        func belongs(to sender: String) -> Bool { senderId == nil || senderId == sender }
    }

    private func directory(for messageId: String) -> URL? {
        UUID(uuidString: messageId).map { root.appendingPathComponent($0.uuidString, isDirectory: true) }
    }

    /// Nil when there is no meta or it does not open: such a directory holds nothing readable, and a
    /// new chunk starts it over rather than failing to be kept.
    private func readMeta(in dir: URL, key: Data) throws -> Meta? {
        guard let sealed = try? Data(contentsOf: dir.appendingPathComponent("meta")),
              let plain = try? MessageStorageCrypto.decrypt(ciphertext: sealed, key: key)
        else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: plain)
    }

    private func storeKey() throws -> Data {
        if let existing = KeychainManager.shared.loadReassemblyStoreKey() { return existing }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Unavailable() }
        KeychainManager.shared.saveReassemblyStoreKey(key)
        guard let stored = KeychainManager.shared.loadReassemblyStoreKey() else { throw Unavailable() }
        return stored
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The crate's `pending_chunks`, keyed by sender and message as here. Off until step 4.
final class LocalStorePendingChunkStore: PendingChunkStore, @unchecked Sendable {

    private let store: LocalStore

    init(session: LocalStoreSession) {
        self.store = session.store
    }

    func add(_ chunk: PendingChunkRecord) throws -> Bool {
        try store.addPendingChunk(chunk: LocalPendingChunk(
            senderId: chunk.senderId, messageId: chunk.messageId,
            chunkIndex: UInt32(chunk.chunkIndex), totalChunks: UInt32(chunk.totalChunks),
            plaintextLength: UInt64(chunk.plaintextLength), contentType: chunk.contentType,
            payload: chunk.payload,
            // Left out on purpose: `PendingChunkRecord` does not carry the envelope, and nothing
            // here reads it back.
            envelopeId: nil,
            receivedAt: chunk.receivedAt.unixMs
        ))
    }

    func chunks(senderId: String, messageId: String) throws -> [PendingChunkRecord] {
        try store.pendingChunks(senderId: senderId, messageId: messageId).map {
            PendingChunkRecord(
                senderId: $0.senderId, messageId: $0.messageId,
                chunkIndex: UInt16(clamping: $0.chunkIndex), totalChunks: UInt16(clamping: $0.totalChunks),
                plaintextLength: Int(clamping: $0.plaintextLength), contentType: $0.contentType,
                payload: $0.payload, receivedAt: Date(unixMs: $0.receivedAt)
            )
        }
    }

    func count(senderId: String, messageId: String) throws -> Int {
        Int(try store.pendingChunkCount(senderId: senderId, messageId: messageId))
    }

    func messages() throws -> [PendingChunkMessage] {
        try store.pendingChunkMessages().map { PendingChunkMessage(senderId: $0.senderId, messageId: $0.messageId) }
    }

    func delete(senderId: String, messageId: String) throws {
        try store.deletePendingChunks(senderId: senderId, messageId: messageId)
    }
}
