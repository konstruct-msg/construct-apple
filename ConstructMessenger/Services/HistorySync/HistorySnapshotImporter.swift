//
//  HistorySnapshotImporter.swift
//  Construct Messenger
//
//  Additive projection of a CTH1 stream into the store. Never replaces store files, never writes
//  the stream cursor, never imports a ratchet. Records arrive already judged by the core (order,
//  phase, manifest ↔ envelope); media arrives through `HistoryMediaSink`, not here.
//
//  How a record meets the rows already held — names only fill in, flags only rise, a block is
//  never lifted, our own message lands sent — is the core's (`history_import_*`,
//  decisions/history-projection-in-the-core.md). This file reads what the store holds, asks the
//  core, and writes the answer through the repositories. Calls still go to Core Data directly
//  until the calls domain is behind the seam.
//

import CoreData
import Foundation

enum HistorySkipReason: Equatable {
    case bodyUnknown
    case hintDroppedBadId
    case mediaAlreadyPresent
    case reactionTargetMissing
}

enum HistoryApplyResult: Equatable {
    case applied
    case conflictKeepExisting
    case skipped(HistorySkipReason)
    case ignored
}

struct HistoryImportSummary: Equatable {
    var applied: Int = 0
    var conflictKeepExisting: Int = 0
    var skipped: [HistorySkipReason: Int] = [:]

    mutating func add(_ result: HistoryApplyResult) {
        switch result {
        case .applied: applied += 1
        case .conflictKeepExisting: conflictKeepExisting += 1
        case .skipped(let reason): skipped[reason, default: 0] += 1
        case .ignored: break
        }
    }

    mutating func merge(_ other: HistoryImportSummary) {
        applied += other.applied
        conflictKeepExisting += other.conflictKeepExisting
        for (reason, count) in other.skipped {
            skipped[reason, default: 0] += count
        }
    }
}

/// One stream's import. Messages are written in batches of `saveBatchSize` — one write each, not
/// one per message — and a batch is written before anything that reads it (a reaction asks
/// whether its message is held). Call `flush()` at the end. Every write goes through a repository;
/// until 2026-10-12 the call rows went into a context the caller passed, which was its only use.
final class HistorySnapshotImporter {
    static let saveBatchSize = 200

    private let expectedUserId: String
    private let contacts: any ContactStore
    private let chats: any ChatStore
    private let messages: any MessageStore
    private let reactions: any ReactionStore
    private let peerDevices: any PeerDeviceStore
    private let calls: any CallStore
    /// The calls already logged here, read at the first call record of the stream.
    private var knownCallIds: Set<String>?
    private(set) var summary = HistoryImportSummary()
    private var pending: [(message: MessageRecord, searchText: String?)] = []
    /// Chat ids by peer, opened this stream.
    private var chatIds: [String: String] = [:]

    init(
        expectedUserId: String,
        contacts: any ContactStore = LocalRepositories.contacts,
        chats: any ChatStore = LocalRepositories.chats,
        messages: any MessageStore = LocalRepositories.messages,
        reactions: any ReactionStore = LocalRepositories.reactions,
        peerDevices: any PeerDeviceStore = LocalRepositories.peerDevices,
        calls: any CallStore = LocalRepositories.calls
    ) {
        self.expectedUserId = expectedUserId
        self.contacts = contacts
        self.chats = chats
        self.messages = messages
        self.reactions = reactions
        self.peerDevices = peerDevices
        self.calls = calls
    }

    /// Apply one record. A refused record aborts the whole phase, and the error alone
    /// ("malformed") does not say which one, so its shape is logged here: kind and size, never
    /// content or ids.
    func apply(_ record: HistoryRecord) throws {
        do {
            try applyUnlogged(record)
        } catch {
            Log.error("history_record_rejected \(record.shape) error=\(error)", category: "HistorySync")
            throw error
        }
    }

    /// Write the messages waiting.
    func flush() throws {
        try writePending()
    }

    /// Apply a whole decoded stream and flush; this stream's summary.
    func importRecords(_ records: [HistoryRecord]) throws -> HistoryImportSummary {
        for record in records { try apply(record) }
        try flush()
        return summary
    }

    private func applyUnlogged(_ record: HistoryRecord) throws {
        switch record {
        case .manifest:
            // Version, phase, and that it names this snapshot and this account: the core's checks,
            // made before it released the record.
            return
        case .skipped(let type):
            if type == HistoryRecordType.message { summary.add(.skipped(.bodyUnknown)) }
        case .transcript(let type, let proto):
            switch type {
            case HistoryRecordType.contact: summary.add(try applyContact(proto))
            case HistoryRecordType.chat: summary.add(try applyChat(proto))
            case HistoryRecordType.message: try applyMessage(proto)
            case HistoryRecordType.reaction:
                try writePending()
                summary.add(try applyReaction(proto))
            case HistoryRecordType.peer: summary.add(try applyPeerHint(proto))
            case HistoryRecordType.call: summary.add(try applyCall(proto))
            default: break
            }
        }
    }

    private var nowMs: Int64 { Date().unixMs }

    // MARK: - Contact

    private func applyContact(_ proto: Data) throws -> HistoryApplyResult {
        let id = try historyImportContact(record: proto, existing: nil, nowMs: nowMs).id
        let held = try contacts.contact(id)
        // A name this app generated is no name: the record's may fill it.
        let generated = held.map { $0.displayName == DisplayNameGenerator.generate(from: id) } ?? false
        let existing = held.map { row -> LocalContact in
            var row = row
            if generated { row.displayName = "" }
            return row.local
        }
        var merged = ContactRecord(try historyImportContact(record: proto, existing: existing, nowMs: nowMs))
        if generated, merged.displayName.isEmpty, let held { merged.displayName = held.displayName }
        if held == nil {
            try contacts.insert(merged)
        } else {
            try contacts.replace(merged)
        }
        return .applied
    }

    // MARK: - Chat

    private func applyChat(_ proto: Data) throws -> HistoryApplyResult {
        let asked = try historyImportChat(record: proto)
        let chatId = try openChat(withPeer: asked.peerId)
        if asked.pin { try chats.setPinned(chatId, true) }
        try chats.setUnread(chatId, 0)
        return .applied
    }

    /// The receiver's chat with `peer` — its own id, never the sender's — made if missing, with
    /// a contact row for it to point at. Made with no time, not `openChat`'s "now": the preview
    /// only moves forward, and an imported message is older than now.
    private func openChat(withPeer peer: String) throws -> String {
        if let id = chatIds[peer] { return id }
        if try contacts.contact(peer) == nil {
            try contacts.insert(.new(id: peer, isContact: false, addedAt: nil))
        }
        let id: String
        if let held = try chats.chat(withPeer: peer) {
            id = held.id
        } else {
            let new = ChatRecord(
                id: UUID().uuidString, peerId: peer, lastMessageText: nil, lastMessageTime: nil,
                isPinned: false, unreadCount: 0
            )
            if try chats.insert(new) {
                id = new.id
            } else if let winner = try chats.chat(withPeer: peer) {
                id = winner.id
            } else {
                throw ChatStoreError.notInserted(peerId: peer)
            }
        }
        chatIds[peer] = id
        return id
    }

    // MARK: - Message

    private func applyMessage(_ proto: Data) throws {
        switch try historyImportMessage(record: proto, ownAccountId: expectedUserId) {
        case .unknownBody:
            summary.add(.skipped(.bodyUnknown))
        case .row(let peerId, let row):
            let message = MessageRecord(row, chatId: try openChat(withPeer: peerId))
            let readable = LocalMessagePayload.decode(message.body).readableText
            pending.append((message, readable.isEmpty ? nil : readable))
            if pending.count >= Self.saveBatchSize { try writePending() }
        }
    }

    /// The batch, one write; then each chat's preview moves to the newest message it gained.
    private func writePending() throws {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let added = try messages.insert(batch)
        summary.applied += added.count
        summary.conflictKeepExisting += batch.count - added.count

        var newest: [String: MessageRecord] = [:]
        for (message, _) in batch where added.contains(message.id) {
            if let held = newest[message.chatId], held.timestamp >= message.timestamp { continue }
            newest[message.chatId] = message
        }
        for (chatId, message) in newest {
            try chats.advancePreview(
                chatId, text: LocalMessagePayload.decode(message.body).previewHint, time: message.timestamp
            )
            try chats.setUnread(chatId, 0)
        }
    }

    // MARK: - Reaction

    private func applyReaction(_ proto: Data) throws -> HistoryApplyResult {
        let row = ReactionRecord(try historyImportReaction(record: proto, receivedAtMs: nowMs))
        guard try messages.message(row.targetMessageId) != nil else {
            return .skipped(.reactionTargetMissing)
        }
        if try reactions.reaction(on: row.targetMessageId, by: row.reactorUserId) != nil {
            return .conflictKeepExisting
        }
        try reactions.upsert(row)
        return .applied
    }

    // MARK: - Peer hint

    private func applyPeerHint(_ proto: Data) throws -> HistoryApplyResult {
        guard let device = try historyImportPeerDevice(record: proto, nowMs: nowMs) else {
            return .skipped(.hintDroppedBadId)
        }
        // A hint is a pin of what the sending device knew, true whether or not the rest of this
        // stream lands — the same standing as a pin from a bundle answer
        // (`SessionAddressing.recordDevices`).
        let recorded = try peerDevices.record([PeerDeviceRecord(device)])
        return recorded.isEmpty ? .conflictKeepExisting : .applied
    }

    // MARK: - Call

    private func applyCall(_ proto: Data) throws -> HistoryApplyResult {
        let unnamed = try historyImportCall(record: proto, peerName: "", nowMs: nowMs)
        var known = try knownCallIds ?? Set(calls.calls(limit: Int(Int32.max)).map(\.id))
        defer { knownCallIds = known }
        if known.contains(unnamed.id) { return .conflictKeepExisting }
        try calls.upsert(CallRecord(
            id: unnamed.id,
            peerUserId: unnamed.peerUserId,
            peerName: try contacts.contact(unnamed.peerUserId)?.displayName ?? "",
            direction: CallRecord.Direction(rawValue: unnamed.direction) ?? .incoming,
            status: CallRecord.Status(rawValue: unnamed.status) ?? .completed,
            startedAt: unnamed.startedAt.map(Date.init(unixMs:)) ?? Date(),
            endedAt: unnamed.endedAt.map(Date.init(unixMs:)),
            durationSeconds: unnamed.durationSeconds
        ))
        known.insert(unnamed.id)
        return .applied
    }
}

private extension HistoryRecord {
    /// What a rejected record looked like, for the log: its type and size.
    var shape: String {
        switch self {
        case .manifest: return "kind=manifest"
        case .transcript(let type, let proto): return "kind=\(type) bytes=\(proto.count)"
        case .skipped(let type): return "kind=skipped type=\(type)"
        }
    }
}
