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
//  removing.
//
//  At rest: `LocalRepositories.pendingChunks` (`PendingChunkStore`) since 2026-10-11 — the file
//  layout this type used to write itself (`FilePendingChunkStore`), and `pending_chunks` in the
//  crate on macOS. A message is one sender's, keyed by sender and message id. This type keeps the
//  rules: when a message is complete, how it is assembled, and when a partial one is given up.
//
//  See decisions/durable-chunk-reassembly.md.
//

import Foundation

struct PendingReassembly {
    let senderId: String
    let messageId: UUID
    let totalChunks: UInt16
    let plaintextLength: Int
    let contentType: UInt8
    var receivedChunks: [UInt16: Data]
    let startedAt: Date

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

    /// The sweep runs on every decrypted message and now reads the store, not a map in memory;
    /// against a retention of a day, once a minute loses nothing.
    static let sweepInterval: TimeInterval = 60

    private let queue = DispatchQueue(label: "construct.PendingReassemblyStore")
    private var lastSweep: Date?

    private var store: any PendingChunkStore { LocalRepositories.pendingChunks }

    private init() {}

    // MARK: - API

    /// Record one chunk. Returns the message once every chunk is present, nil while it is still
    /// incomplete. The bytes are in the store before this returns, so the caller may safely treat
    /// the envelope as handled.
    func put(
        senderId: String,
        messageId: UUID,
        chunkIndex: UInt16,
        totalChunks: UInt16,
        plaintextLength: Int,
        contentType: UInt8,
        payload: Data,
        now: Date = Date()
    ) -> PendingReassembly? {
        queue.sync {
            let id = messageId.uuidString.lowercased()
            do {
                try store.add(PendingChunkRecord(
                    senderId: senderId, messageId: id, chunkIndex: chunkIndex, totalChunks: totalChunks,
                    plaintextLength: plaintextLength, contentType: contentType, payload: payload,
                    receivedAt: now
                ))
                // The count first: reading every chunk on every arrival is quadratic in the size.
                guard try store.count(senderId: senderId, messageId: id) == Int(totalChunks) else { return nil }
                let entry = try reassembly(senderId: senderId, messageId: messageId)
                return entry?.isComplete == true ? entry : nil
            } catch {
                Log.error(
                    "Reassembly store: chunk \(chunkIndex) of \(id.prefix(8))… not kept — the partial message will not survive a restart: \(error)",
                    category: "ChunkedDelivery"
                )
                return nil
            }
        }
    }

    /// Drop a completed (or abandoned) reassembly.
    func remove(senderId: String, messageId: UUID) {
        queue.sync {
            try? store.delete(senderId: senderId, messageId: messageId.uuidString.lowercased())
        }
    }

    /// Expire anything past `retention`, reporting each as a real loss. Call on any decrypted
    /// message so a stalled reassembly surfaces while ordinary traffic keeps flowing; it looks at
    /// the store at most once per `sweepInterval`.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> [PendingReassembly] {
        queue.sync {
            if let lastSweep, now.timeIntervalSince(lastSweep) < Self.sweepInterval, now >= lastSweep { return [] }
            lastSweep = now
            return sweep(now: now)
        }
    }

    /// Every partial message dropped, without reporting it as a loss — it was the last account's
    /// (`AuthViewModel`'s ownership gate), and the next one never received it.
    func removeAll() {
        queue.sync {
            do {
                for message in try store.messages() {
                    try store.delete(senderId: message.senderId, messageId: message.messageId)
                }
            } catch {
                Log.error("Reassembly store: partial messages not dropped: \(error)", category: "ChunkedDelivery")
            }
        }
    }

    /// Test/diagnostic view of what is currently held.
    func pendingCount() -> Int {
        queue.sync { (try? store.messages().count) ?? 0 }
    }

    #if DEBUG
    /// The next sweep looks at the store whatever the time since the last one.
    func resetSweepThrottleForTesting() {
        queue.sync { lastSweep = nil }
    }
    #endif

    // MARK: - Expiry

    private func sweep(now: Date) -> [PendingReassembly] {
        guard let held = try? store.messages() else { return [] }
        var expired: [PendingReassembly] = []
        for message in held {
            guard let uuid = UUID(uuidString: message.messageId),
                  let entry = try? reassembly(senderId: message.senderId, messageId: uuid),
                  now.timeIntervalSince(entry.startedAt) > Self.retention
            else { continue }
            Log.error(
                "Chunked message LOST for \(entry.messageId.uuidString.prefix(8))… — \(entry.receivedChunks.count)/\(entry.totalChunks) chunks after \(Int(now.timeIntervalSince(entry.startedAt)))s, missing indices \(entry.missingIndices.prefix(16).map(String.init).joined(separator: ",")) — not recoverable (ratchet keys for the missing chunks are consumed)",
                category: "ChunkedDelivery"
            )
            PerformanceMetrics.shared.record(
                .chunkReassemblyExpired,
                label: String(entry.messageId.uuidString.prefix(8))
            )
            try? store.delete(senderId: message.senderId, messageId: message.messageId)
            expired.append(entry)
        }
        return expired
    }

    private func reassembly(senderId: String, messageId: UUID) throws -> PendingReassembly? {
        let chunks = try store.chunks(senderId: senderId, messageId: messageId.uuidString.lowercased())
        guard let first = chunks.first else { return nil }
        return PendingReassembly(
            senderId: senderId,
            messageId: messageId,
            totalChunks: first.totalChunks,
            plaintextLength: first.plaintextLength,
            contentType: first.contentType,
            receivedChunks: Dictionary(chunks.map { ($0.chunkIndex, $0.payload) }, uniquingKeysWith: { held, _ in held }),
            startedAt: chunks.map(\.receivedAt).min() ?? first.receivedAt
        )
    }
}
