//
//  ChatStore.swift
//  Construct Messenger
//
//  The chats as a repository: values in, values out, no managed object and no context. The chats
//  domain of the storage seam (`client/specs/LOCAL_STORE_MIGRATION_PLAN.md` step 1). Core Data
//  answers today; `LocalStore` (construct-store schema 3, construct-core 0.36.0) takes over on
//  macOS in step 3, with `chat`, `chat_for_peer`, `chats`, `insert_chat` and the field writes.
//
//  One chat per peer. The crate holds that with a unique index; Core Data has none, so a chat for
//  a peer is chosen among duplicates here and merged by `Chat.findOrCreate`, which the message
//  path still uses until the messages domain moves.
//

import Foundation
import CoreData

/// One conversation with one person.
///
/// `isMuted` and `sessionId` are left out on purpose: nothing sets the first (its setter had no
/// caller, and the crate dropped it in schema 3) and nothing writes the second.
struct ChatRecord: Equatable, Sendable, Identifiable {
    let id: String
    /// The account we talk to — a `ServerUserId`. Its row is `ContactStore`'s.
    let peerId: String
    /// The list's preview, as `Chat.formatPreviewText` made it.
    var lastMessageText: String?
    var lastMessageTime: Date?
    var isPinned: Bool
    var unreadCount: Int
}

protocol ChatStore: Sendable {
    func chat(_ id: String) throws -> ChatRecord?

    /// The chat with `peerId`, if there is one.
    func chat(withPeer peerId: String) throws -> ChatRecord?

    /// Pinned first, then most recent, chats with no message last; id breaks ties.
    func chats() throws -> [ChatRecord]

    /// The ids of chats written or deleted, once per save. Subscribe before the first read, or a
    /// write between the two is missed.
    func changes() -> AsyncStream<Set<String>>

    // MARK: Writes

    /// Adds the chat unless its id or its peer has one; true when added. The peer's contact row
    /// must exist — it is `ContactStore`'s to write.
    @discardableResult func insert(_ chat: ChatRecord) throws -> Bool

    /// Moves the preview unless the one shown is newer; an equal time moves it — outgoing times
    /// are whole seconds, and a message sent in the preview's second must still show.
    @discardableResult func advancePreview(_ id: String, text: String, time: Date) throws -> Bool
    /// Sets the preview whatever it was — after a deletion; both `nil` when no message is left.
    @discardableResult func setPreview(_ id: String, text: String?, time: Date?) throws -> Bool
    @discardableResult func incrementUnread(_ id: String) throws -> Bool
    @discardableResult func setUnread(_ id: String, _ count: Int) throws -> Bool
    @discardableResult func setPinned(_ id: String, _ pinned: Bool) throws -> Bool
    /// The chat and its messages. The contact stays.
    func delete(_ id: String) throws
}

extension ChatStore {
    /// The chat with `peerId`, added if there is none. A new one shows `now` as its time, so a
    /// chat just opened sits at the top of the list before anything is said in it; an existing
    /// one with no time gets `now` too, for the same reason.
    ///
    /// Two callers opening a chat with one person get one chat: an insert that loses the race
    /// reads the winner's.
    func openChat(withPeer peerId: String, now: Date = Date()) throws -> (chat: ChatRecord, created: Bool) {
        if var existing = try chat(withPeer: peerId) {
            if existing.lastMessageTime == nil, try setPreview(existing.id, text: existing.lastMessageText, time: now) {
                existing.lastMessageTime = now
            }
            return (existing, false)
        }
        let new = ChatRecord(
            id: UUID().uuidString, peerId: peerId, lastMessageText: nil, lastMessageTime: now,
            isPinned: false, unreadCount: 0
        )
        if try insert(new) { return (new, true) }
        guard let winner = try chat(withPeer: peerId) else {
            throw ChatStoreError.notInserted(peerId: peerId)
        }
        return (winner, false)
    }
}

enum ChatStoreError: Error {
    /// The peer has no contact row, so no chat can point at it.
    case noContact(peerId: String)
    /// The insert reported a chat for the peer that a read then did not find.
    case notInserted(peerId: String)
}

/// `Chat` rows. Each call runs on a fresh background context, for the reason
/// `CoreDataPeerDeviceStore` gives; it therefore sees what is saved, never another context's
/// pending changes.
final class CoreDataChatStore: ChatStore, @unchecked Sendable {

    private let container: NSPersistentContainer
    private let feed: RowChangeFeed

    init(container: NSPersistentContainer) {
        self.container = container
        self.feed = RowChangeFeed(coordinator: container.persistentStoreCoordinator) { object in
            switch object {
            case let chat as Chat: return chat.id
            // A message saved changes its chat's list row only through the chat's own fields,
            // which mark the chat updated too; a message on its own is the messages domain's.
            default: return nil
            }
        }
    }

    func changes() -> AsyncStream<Set<String>> { feed.stream() }

    func chat(_ id: String) throws -> ChatRecord? {
        try run { context in try Self.row(id, in: context).flatMap(ChatRecord.init(row:)) }
    }

    func chat(withPeer peerId: String) throws -> ChatRecord? {
        try run { context in try Self.best(forPeer: peerId, in: context).flatMap(ChatRecord.init(row:)) }
    }

    func chats() throws -> [ChatRecord] {
        try run { context in
            let req = Chat.fetchRequest()
            return try context.fetch(req).compactMap(ChatRecord.init(row:)).sorted(by: ChatRecord.listOrder)
        }
    }

    // MARK: Writes

    func insert(_ chat: ChatRecord) throws -> Bool {
        try run { context in
            if try Self.row(chat.id, in: context) != nil { return false }
            if try Self.best(forPeer: chat.peerId, in: context) != nil { return false }
            let users = User.fetchRequest()
            users.predicate = NSPredicate(format: "id == %@", chat.peerId)
            users.fetchLimit = 1
            guard let peer = try context.fetch(users).first else {
                throw ChatStoreError.noContact(peerId: chat.peerId)
            }
            let row = Chat(context: context)
            row.id = chat.id
            row.otherUser = peer
            row.lastMessageText = chat.lastMessageText
            row.lastMessageTime = chat.lastMessageTime
            row.isPinned = chat.isPinned
            row.isMuted = false
            row.unreadCount = Int16(clamping: chat.unreadCount)
            try context.saveOrThrow(category: "Chats")
            return true
        }
    }

    func advancePreview(_ id: String, text: String, time: Date) throws -> Bool {
        try update(id) { chat in
            if let current = chat.lastMessageTime, time < current { return false }
            chat.lastMessageText = text
            chat.lastMessageTime = time
            return true
        }
    }

    func setPreview(_ id: String, text: String?, time: Date?) throws -> Bool {
        try update(id) { $0.lastMessageText = text; $0.lastMessageTime = time; return true }
    }

    func incrementUnread(_ id: String) throws -> Bool {
        try update(id) { $0.unreadCount = $0.unreadCount < .max ? $0.unreadCount + 1 : .max; return true }
    }

    func setUnread(_ id: String, _ count: Int) throws -> Bool {
        try update(id) { $0.unreadCount = Int16(clamping: count); return true }
    }

    func setPinned(_ id: String, _ pinned: Bool) throws -> Bool {
        try update(id) { $0.isPinned = pinned; return true }
    }

    func delete(_ id: String) throws {
        try run { context in
            guard let chat = try Self.row(id, in: context) else { return }
            // `messages` cascades and `otherUser` nullifies: the transcript goes, the contact stays.
            context.delete(chat)
            try context.saveOrThrow(category: "Chats")
        }
    }

    /// The fields `change` names, saved when it reports a change; false when there is no such
    /// chat or `change` declined.
    private func update(_ id: String, _ change: (Chat) -> Bool) throws -> Bool {
        try run { context in
            guard let chat = try Self.row(id, in: context) else { return false }
            guard change(chat) else { return false }
            // A write of the values already there saves nothing, so it announces nothing: the
            // chats list re-checks previews on every save, and an idle save would wake it again.
            if !chat.changedValues().isEmpty { try context.saveOrThrow(category: "Chats") }
            return true
        }
    }

    private static func row(_ id: String, in context: NSManagedObjectContext) throws -> Chat? {
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        return try context.fetch(req).first
    }

    /// The chat for `peerId` — among duplicates, the one `Chat.findOrCreate` keeps when it merges
    /// them, so a read here and a merge there agree on which id survives.
    private static func best(forPeer peerId: String, in context: NSManagedObjectContext) throws -> Chat? {
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "otherUser.id == %@", peerId)
        let rows = try context.fetch(req)
        return rows.count > 1 ? Chat.selectBestChat(among: rows) : rows.first
    }

    private func run<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = container.newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}

extension ChatRecord {
    /// A row with no peer — its contact deleted under it, which `otherUser`'s nullify allows — is
    /// no chat anyone can open, and is skipped.
    init?(row chat: Chat) {
        guard let peerId = chat.otherUser?.id, !peerId.isEmpty else { return nil }
        self.init(
            id: chat.id, peerId: peerId, lastMessageText: chat.lastMessageText,
            lastMessageTime: chat.lastMessageTime, isPinned: chat.isPinned,
            unreadCount: Int(chat.unreadCount)
        )
    }

    /// Pinned first, then most recent, chats with no message last; id breaks ties — the crate's
    /// `chats()` order.
    static func listOrder(_ a: ChatRecord, _ b: ChatRecord) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        switch (a.lastMessageTime, b.lastMessageTime) {
        case let (ta?, tb?) where ta != tb: return ta > tb
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.id < b.id
        }
    }
}

extension Chat {
    /// The row `id` in `context`, as last saved — for a caller that still needs the managed object
    /// (messages to link, a screen to open) after writing through `ChatStore`. Refreshed, for the
    /// reason `User.row` gives. Disappears with the messages domain.
    static func row(_ id: String, in context: NSManagedObjectContext) throws -> Chat {
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        req.shouldRefreshRefetchedObjects = true
        guard let chat = try context.fetch(req).first else {
            throw NSError(domain: "ChatStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Chat row \(id.prefix(8))…"])
        }
        return chat
    }
}
