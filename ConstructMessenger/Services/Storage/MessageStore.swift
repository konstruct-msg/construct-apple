//
//  MessageStore.swift
//  Construct Messenger
//
//  The messages as a repository: values in, values out, no managed object and no context. The
//  messages domain of the storage seam (`client/specs/LOCAL_STORE_MIGRATION_PLAN.md`, messages
//  B1). Core Data answers today; `LocalStore` (construct-store 0.4.0, construct-core 0.37.0) takes
//  over on macOS in step 3 with `insert_message`, `edit_message`, `set_delivery_status`,
//  `apply_session_archive`, the field writes and `messages_before`.
//
//  The body crosses this seam as what the message says — the local payload (CTM1 or legacy UTF-8)
//  — never as ciphertext. Core Data seals each row under a key of its own (`applyStoredEncryption`,
//  `MessageKeyStore`); the store encrypts the whole database instead. That difference stays inside
//  the implementations.
//

import Foundation
import CoreData

/// One message of a conversation, as the store holds it.
///
/// Left out on purpose: the legacy plaintext columns (`decryptedContent`, `replyToContent`,
/// `transcriptText`) — the getters below read them as the sealed fields' fallback, and nothing
/// writes them — and the row key (`contentKeyRef`), which is the Core Data implementation's own.
struct MessageRecord: Equatable, Sendable, Identifiable {
    let id: String
    let chatId: String
    var fromUserId: String
    var toUserId: String
    var isSentByMe: Bool
    var timestamp: Date
    /// Transcript order (`ServerMessageOrder`): the server's key once it placed the message, a
    /// pending or local key before.
    var orderKey: String
    /// The local payload: CTM1 or legacy UTF-8 (`LocalMessagePayload`).
    var body: Data
    var contentType: MessageContentType
    var deliveryStatus: DeliveryStatus
    var retryCount: Int16
    var suiteId: UInt16
    var isEdited: Bool
    var editedAt: Date?
    var replyToMessageId: String?
    /// The quote in its stored form (`ReplyPreviewPayload`).
    var replyQuote: String?
    var transcript: String?
    var transcriptLanguage: String?
    var transcriptGeneratedAt: Date?

    /// The account on the other side of this message.
    var peerId: String { isSentByMe ? toUserId : fromUserId }

    /// The body decoded: what `Message.legacyBody` (`displayString`) and `plainText` read on a
    /// managed row.
    var payload: LocalMessagePayload { LocalMessagePayload.decode(body) }
}

protocol MessageStore: Sendable {
    /// The message `id`. Ids are compared without case: rows written before ids were lowercased
    /// at the seam still answer.
    func message(_ id: String) throws -> MessageRecord?

    /// Up to `limit` messages of a chat just before `before` — `(orderKey, id)` of the oldest one
    /// held, `nil` for the newest page — oldest first.
    func messages(inChat chatId: String, before: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord]

    /// Up to `limit` messages of a chat from `from` — `(orderKey, id)`, included — onwards, oldest
    /// first: the window an open transcript holds, read again after a write (`messages_from`).
    func messages(inChat chatId: String, from: (orderKey: String, id: String), limit: Int) throws -> [MessageRecord]

    /// How many messages the chat holds, every kind — the activity Synapses ranks a contact by
    /// (`chat_message_count`).
    func messageCount(inChat chatId: String) throws -> Int

    /// Every message in transcript order after `after` — `(orderKey, id)` of the last one read,
    /// `nil` to start — up to `limit`: a history export reads them page by page
    /// (`all_messages_after`).
    func allMessages(after: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord]

    /// Ours waiting to be sent: queued, or failed with `retryCount < retryCeiling`; in one chat,
    /// or every chat for `nil`. Transcript order (`pending_sends`).
    func pendingSends(inChat chatId: String?, retryCeiling: Int16, limit: Int) throws -> [MessageRecord]

    /// Ours in `status`, every chat, transcript order (`own_messages_in_status`).
    func ownMessages(in status: DeliveryStatus, limit: Int) throws -> [MessageRecord]

    /// The ids of messages written or deleted, once per save.
    func changes() -> AsyncStream<Set<String>>

    // MARK: Writes

    /// Adds the message unless one with its id is there; true when added. The chat must exist.
    /// `searchText` — what the message says, for the full-text index; `nil` for media and control.
    @discardableResult func insert(_ message: MessageRecord, searchText: String?) throws -> Bool

    /// `insert` for each, in one write: a history import lands thousands at once. Returns the
    /// ids added; one already held is kept.
    @discardableResult func insert(_ messages: [(message: MessageRecord, searchText: String?)]) throws -> Set<String>

    /// An edit: the body replaced, the message marked edited at `editedAt`.
    @discardableResult func edit(_ id: String, body: Data, searchText: String?, editedAt: Date) throws -> Bool

    /// A body read late — a message stored undecryptable, sent again under the same id: replaced,
    /// and **not** marked edited, since it says what it said all along (`set_message_body`).
    @discardableResult func setBody(_ id: String, body: Data, searchText: String?) throws -> Bool

    /// Writes `status` unless the stored one is stronger evidence of arrival
    /// (`DeliveryStatusTransition`); false when refused, unchanged, or no such message.
    @discardableResult func setDeliveryStatus(_ id: String, _ status: DeliveryStatus) throws -> Bool

    /// The session the message was encrypted under was archived: keep, queue again, or fail once
    /// `maxRetries` is spent — the one write allowed to lower `.sent`. `nil`: no such message.
    func applySessionArchive(_ id: String, maxRetries: Int16) throws -> DeliveryStatusTransition.ArchiveOutcome?

    @discardableResult func setRetryCount(_ id: String, _ count: Int16) throws -> Bool
    /// One more attempt, counted in the store; the new count, `nil` for no message.
    func incrementRetryCount(_ id: String) throws -> Int16?
    @discardableResult func setOrderKey(_ id: String, _ orderKey: String) throws -> Bool
    /// All `nil` clears it.
    @discardableResult func setTranscript(
        _ id: String, text: String?, language: String?, generatedAt: Date?
    ) throws -> Bool

    func delete(_ ids: Set<String>) throws
}

extension MessageStore {
    /// The peer has the message, so it is not waiting for a position any more: a row of ours
    /// still on the `pending` key moves to its own time. Without this a send whose acknowledgement
    /// was lost — the receipt came, the RPC then failed — kept the pending key for good and sat
    /// below every later message (2026-10-12). The acknowledgement, if it still comes, moves the
    /// row on to the server's key. False when the row was not pending.
    @discardableResult func settleOrder(of record: MessageRecord) throws -> Bool {
        guard ServerMessageOrder.isPending(record.orderKey) else { return false }
        return try setOrderKey(record.id, ServerMessageOrder.local(timestamp: record.timestamp, messageId: record.id))
    }
}

/// `Message` rows. Each call runs on a fresh background context, for the reason
/// `CoreDataPeerDeviceStore` gives.
final class CoreDataMessageStore: MessageStore, @unchecked Sendable {

    private let container: NSPersistentContainer
    private let feed: RowChangeFeed

    init(container: NSPersistentContainer) {
        self.container = container
        self.feed = RowChangeFeed(coordinator: container.persistentStoreCoordinator) { object in
            (object as? Message).map(\.id)
        }
    }

    func changes() -> AsyncStream<Set<String>> { feed.stream() }

    func message(_ id: String) throws -> MessageRecord? {
        try run { context in try Self.row(id, in: context).flatMap(MessageRecord.init(row:)) }
    }

    func messages(inChat chatId: String, before: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord] {
        try run { context in
            let req = Message.fetchRequest()
            var predicates = [NSPredicate(format: "chat.id == %@", chatId)]
            if let before {
                predicates.append(NSPredicate(
                    format: "serverOrderKey < %@ OR (serverOrderKey == %@ AND id < %@)",
                    before.orderKey, before.orderKey, before.id
                ))
            }
            req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            req.sortDescriptors = [
                NSSortDescriptor(key: "serverOrderKey", ascending: false),
                NSSortDescriptor(key: "id", ascending: false),
            ]
            req.fetchLimit = limit
            return try context.fetch(req).compactMap(MessageRecord.init(row:)).reversed()
        }
    }

    func messages(inChat chatId: String, from: (orderKey: String, id: String), limit: Int) throws -> [MessageRecord] {
        try run { context in
            let req = Message.fetchRequest()
            req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "chat.id == %@", chatId),
                NSPredicate(
                    format: "serverOrderKey > %@ OR (serverOrderKey == %@ AND id >= %@)",
                    from.orderKey, from.orderKey, from.id
                ),
            ])
            req.sortDescriptors = [
                NSSortDescriptor(key: "serverOrderKey", ascending: true),
                NSSortDescriptor(key: "id", ascending: true),
            ]
            req.fetchLimit = limit
            return try context.fetch(req).compactMap(MessageRecord.init(row:))
        }
    }

    func messageCount(inChat chatId: String) throws -> Int {
        try run { context in
            let req = Message.fetchRequest()
            req.predicate = NSPredicate(format: "chat.id == %@", chatId)
            return try context.count(for: req)
        }
    }

    // MARK: Writes

    func allMessages(after: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord] {
        try run { context in
            let req = Message.fetchRequest()
            if let after {
                // A nil key never answers: `PersistenceController` fills them at launch.
                req.predicate = NSPredicate(
                    format: "serverOrderKey > %@ OR (serverOrderKey == %@ AND id > %@)",
                    after.orderKey, after.orderKey, after.id
                )
            }
            req.sortDescriptors = [
                NSSortDescriptor(key: "serverOrderKey", ascending: true),
                NSSortDescriptor(key: "id", ascending: true),
            ]
            req.fetchLimit = limit
            return try context.fetch(req).compactMap(MessageRecord.init(row:))
        }
    }

    func pendingSends(inChat chatId: String?, retryCeiling: Int16, limit: Int) throws -> [MessageRecord] {
        try ownMessages(limit: limit, NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.queued.rawValue),
            NSPredicate(
                format: "deliveryStatusRaw == %d AND retryCount < %d",
                DeliveryStatus.failed.rawValue, retryCeiling
            ),
        ]), chatId.map { NSPredicate(format: "chat.id == %@", $0) })
    }
    func ownMessages(in status: DeliveryStatus, limit: Int) throws -> [MessageRecord] {
        try ownMessages(limit: limit, NSPredicate(format: "deliveryStatusRaw == %d", status.rawValue))
    }
    private func ownMessages(limit: Int, _ predicates: NSPredicate?...) throws -> [MessageRecord] {
        try run { context in
            let req = Message.fetchRequest()
            req.predicate = NSCompoundPredicate(
                andPredicateWithSubpredicates: [NSPredicate(format: "isSentByMe == YES")] + predicates.compactMap { $0 }
            )
            req.sortDescriptors = [
                NSSortDescriptor(key: "serverOrderKey", ascending: true),
                NSSortDescriptor(key: "id", ascending: true),
            ]
            req.fetchLimit = limit
            return try context.fetch(req).compactMap(MessageRecord.init(row:))
        }
    }

    func insert(_ message: MessageRecord, searchText: String?) throws -> Bool {
        try run { context in
            guard try Self.insertRow(message, in: context) else { return false }
            try context.saveOrThrow(category: "Messages")
            return true
        }
    }

    func insert(_ messages: [(message: MessageRecord, searchText: String?)]) throws -> Set<String> {
        guard !messages.isEmpty else { return [] }
        return try run { context in
            var added = Set<String>()
            for (message, _) in messages where try Self.insertRow(message, in: context) {
                added.insert(message.id)
            }
            if !added.isEmpty { try context.saveOrThrow(category: "Messages") }
            return added
        }
    }

    /// The row for `message` in `context`, unsaved; false when one with its id is there.
    private static func insertRow(_ message: MessageRecord, in context: NSManagedObjectContext) throws -> Bool {
        if try Self.row(message.id, in: context) != nil { return false }
        let chats = Chat.fetchRequest()
        chats.predicate = NSPredicate(format: "id == %@", message.chatId)
        chats.fetchLimit = 1
        guard let chat = try context.fetch(chats).first else {
            throw MessageStoreError.noChat(chatId: message.chatId)
        }
        let row = Message(context: context)
        row.id = message.id
        row.chat = chat
        row.fromUserId = message.fromUserId
        row.toUserId = message.toUserId
        row.isSentByMe = message.isSentByMe
        row.timestamp = message.timestamp
        row.serverOrderKey = message.orderKey
        row.contentType = message.contentType
        row.deliveryStatusRaw = message.deliveryStatus.rawValue
        row.retryCount = message.retryCount
        row.suiteId = message.suiteId
        row.isEdited = message.isEdited
        row.editedAt = message.editedAt
        row.replyToMessageId = message.replyToMessageId
        // The body first: it makes the row's key, which the quote and transcript are sealed
        // under. `applyStoredEncryption` may stamp a content type it infers from the body;
        // the record's own type is set again after it.
        row.applyStoredEncryption(plaintextData: message.body, contactId: message.peerId)
        if message.contentType != .regular { row.contentType = message.contentType }
        row.replyQuote = message.replyQuote
        row.transcript = message.transcript
        row.transcriptLanguage = message.transcriptLanguage
        row.transcriptGeneratedAt = message.transcriptGeneratedAt
        return true
    }

    func edit(_ id: String, body: Data, searchText: String?, editedAt: Date) throws -> Bool {
        try update(id) { row in
            row.applyStoredEncryption(plaintextData: body, contactId: row.isSentByMe ? row.toUserId : row.fromUserId)
            row.isEdited = true
            row.editedAt = editedAt
        }
    }

    func setBody(_ id: String, body: Data, searchText: String?) throws -> Bool {
        try update(id) { row in
            row.applyStoredEncryption(plaintextData: body, contactId: row.isSentByMe ? row.toUserId : row.fromUserId)
        }
    }

    func setDeliveryStatus(_ id: String, _ status: DeliveryStatus) throws -> Bool {
        // The guarded setter applies `DeliveryStatusTransition`; a refused write changes nothing.
        try update(id) { $0.deliveryStatus = status }
    }

    func applySessionArchive(_ id: String, maxRetries: Int16) throws -> DeliveryStatusTransition.ArchiveOutcome? {
        try run { context in
            guard let row = try Self.row(id, in: context) else { return nil }
            let outcome = DeliveryStatusTransition.afterSessionArchive(
                status: row.deliveryStatus, retryCount: Int(row.retryCount), maxRetries: Int(maxRetries)
            )
            if row.applyArchiveOutcome(outcome) { try context.saveOrThrow(category: "Messages") }
            return outcome
        }
    }

    func setRetryCount(_ id: String, _ count: Int16) throws -> Bool {
        try update(id) { $0.retryCount = count }
    }

    func incrementRetryCount(_ id: String) throws -> Int16? {
        try run { context in
            guard let row = try Self.row(id, in: context) else { return nil }
            row.retryCount = row.retryCount < .max ? row.retryCount + 1 : .max
            try context.saveOrThrow(category: "Messages")
            return row.retryCount
        }
    }

    func setOrderKey(_ id: String, _ orderKey: String) throws -> Bool {
        try update(id) { $0.serverOrderKey = orderKey }
    }

    func setTranscript(_ id: String, text: String?, language: String?, generatedAt: Date?) throws -> Bool {
        try update(id) { row in
            if row.transcript != text { row.transcript = text }
            row.transcriptLanguage = language
            row.transcriptGeneratedAt = generatedAt
        }
    }

    func delete(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try run { context in
            let req = Message.fetchRequest()
            req.predicate = NSPredicate(format: "id IN %@", Set(ids.map { $0.lowercased() }).union(ids))
            let rows = try context.fetch(req)
            guard !rows.isEmpty else { return }
            for row in rows {
                MessageDisplayCache.shared.evict(messageId: row.id)
                context.delete(row)
            }
            try context.saveOrThrow(category: "Messages")
        }
    }

    /// The fields `change` names; saved only when a value did change, so a write of what is
    /// already there announces nothing.
    private func update(_ id: String, _ change: (Message) -> Void) throws -> Bool {
        try run { context in
            guard let row = try Self.row(id, in: context) else { return false }
            change(row)
            guard !row.changedValues().isEmpty else { return false }
            try context.saveOrThrow(category: "Messages")
            return true
        }
    }

    private static func row(_ id: String, in context: NSManagedObjectContext) throws -> Message? {
        let req = Message.fetchRequest()
        req.predicate = NSPredicate(format: "id ==[c] %@", id)
        req.fetchLimit = 1
        return try context.fetch(req).first
    }

    private func run<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = container.newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}

enum MessageStoreError: Error {
    /// The message names a chat the store does not hold.
    case noChat(chatId: String)
}

extension MessageRecord {
    /// A row with no chat — its chat deleted under it — belongs to no conversation and is skipped.
    init?(row: Message) {
        guard let chatId = row.chat?.id else { return nil }
        self.init(
            id: row.id, chatId: chatId, fromUserId: row.fromUserId, toUserId: row.toUserId,
            isSentByMe: row.isSentByMe, timestamp: row.safeTimestamp,
            orderKey: ServerMessageOrder.effectiveKey(for: row),
            body: MessageDisplayCache.shared.payloadData(for: row),
            contentType: row.contentType, deliveryStatus: row.deliveryStatus,
            retryCount: row.retryCount, suiteId: row.suiteId, isEdited: row.isEdited,
            editedAt: row.editedAt, replyToMessageId: row.replyToMessageId,
            replyQuote: row.replyQuote, transcript: row.transcript,
            transcriptLanguage: row.transcriptLanguage, transcriptGeneratedAt: row.transcriptGeneratedAt
        )
    }
}

/// The crate's `messages`. Off until step 4 switches macOS over (`LocalRepositories`). The whole
/// database is encrypted, so the body is stored as it is — no per-row key (`MessageKeyStore`).
/// The rules — an insert never overwrites, the delivery-status order, the archive outcome, the
/// retry count — are the crate's statements.
///
/// Message ids cross in lowercase: the crate compares exactly, and rows written before ids were
/// lowercased at the seam exist only in Core Data. Chat ids are not touched.
final class LocalStoreMessageStore: MessageStore, @unchecked Sendable {

    private let session: LocalStoreSession
    private var store: LocalStore { session.store }

    init(session: LocalStoreSession) {
        self.session = session
    }

    func changes() -> AsyncStream<Set<String>> { session.changes(of: .messages) }

    func message(_ id: String) throws -> MessageRecord? {
        try store.message(id: id.lowercased()).map { MessageRecord($0) }
    }

    func messages(inChat chatId: String, before: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord] {
        try store.messagesBefore(
            chatId: chatId, beforeOrderKey: before?.orderKey, beforeId: before?.id.lowercased(),
            limit: UInt32(clamping: limit)
        ).map { MessageRecord($0) }
    }

    func messages(inChat chatId: String, from: (orderKey: String, id: String), limit: Int) throws -> [MessageRecord] {
        try store.messagesFrom(
            chatId: chatId, fromOrderKey: from.orderKey, fromId: from.id.lowercased(),
            limit: UInt32(clamping: limit)
        ).map { MessageRecord($0) }
    }

    func messageCount(inChat chatId: String) throws -> Int {
        Int(clamping: try store.chatMessageCount(chatId: chatId))
    }

    func allMessages(after: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord] {
        try store.allMessagesAfter(
            afterOrderKey: after?.orderKey, afterId: after?.id.lowercased(), limit: UInt32(clamping: limit)
        ).map { MessageRecord($0) }
    }
    func pendingSends(inChat chatId: String?, retryCeiling: Int16, limit: Int) throws -> [MessageRecord] {
        try store.pendingSends(chatId: chatId, retryCeiling: retryCeiling, limit: UInt32(clamping: limit))
            .map { MessageRecord($0) }
    }
    func ownMessages(in status: DeliveryStatus, limit: Int) throws -> [MessageRecord] {
        try store.ownMessagesInStatus(status: status.rawValue, limit: UInt32(clamping: limit))
            .map { MessageRecord($0) }
    }

    // MARK: Writes

    func insert(_ message: MessageRecord, searchText: String?) throws -> Bool {
        try store.insertMessage(message: Self.row(message), searchText: searchText) == .inserted
    }

    func insert(_ messages: [(message: MessageRecord, searchText: String?)]) throws -> Set<String> {
        guard !messages.isEmpty else { return [] }
        let added = try store.insertMessages(messages: messages.map {
            LocalMessageInsert(message: Self.row($0.message), searchText: $0.searchText)
        })
        return Set(added)
    }

    func edit(_ id: String, body: Data, searchText: String?, editedAt: Date) throws -> Bool {
        try store.editMessage(id: id.lowercased(), body: body, searchText: searchText, editedAt: editedAt.unixMs)
    }

    func setBody(_ id: String, body: Data, searchText: String?) throws -> Bool {
        try store.setMessageBody(id: id.lowercased(), body: body, searchText: searchText)
    }

    func setDeliveryStatus(_ id: String, _ status: DeliveryStatus) throws -> Bool {
        try store.setDeliveryStatus(id: id.lowercased(), status: status.rawValue)
    }

    func applySessionArchive(_ id: String, maxRetries: Int16) throws -> DeliveryStatusTransition.ArchiveOutcome? {
        switch try store.applySessionArchive(id: id.lowercased(), maxRetries: maxRetries) {
        case .keep?: return .keep
        case .resend?: return .resend
        case .giveUp?: return .giveUp
        case nil: return nil
        }
    }

    func setRetryCount(_ id: String, _ count: Int16) throws -> Bool {
        try store.setRetryCount(id: id.lowercased(), count: count)
    }

    func incrementRetryCount(_ id: String) throws -> Int16? {
        try store.incrementRetryCount(id: id.lowercased())
    }

    func setOrderKey(_ id: String, _ orderKey: String) throws -> Bool {
        try store.setOrderKey(id: id.lowercased(), orderKey: orderKey)
    }

    func setTranscript(_ id: String, text: String?, language: String?, generatedAt: Date?) throws -> Bool {
        try store.setTranscript(id: id.lowercased(), text: text, language: language, generatedAt: generatedAt?.unixMs)
    }

    func delete(_ ids: Set<String>) throws {
        for id in Set(ids.map { $0.lowercased() }) {
            try store.deleteMessage(id: id)
            MessageDisplayCache.shared.evict(messageId: id)
        }
    }

    /// The crate's row for `message`: its id lowercased, and a `.regular` body that is a leaked
    /// control payload typed as one — `MessageContentType.infer`, the same call Core Data's
    /// `applyStoredEncryption` makes, so a control message never shows as a bubble on either.
    private static func row(_ message: MessageRecord) -> LocalMessage {
        var row = message.local
        row.id = message.id.lowercased()
        if message.contentType == .regular {
            row.contentType = MessageContentType.infer(from: message.body).rawValue
        }
        return row
    }
}
