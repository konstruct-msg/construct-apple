//
//  Chat+FindOrCreate.swift
//  Construct Messenger
//
//  Single 1:1 invariant: at most one Chat per peer User (`otherUser.id`).
//  All create paths must go through here so parallel flows (Synaps open,
//  invite startChat, MessageRouter, BG fetch, PKB recreate, engine) cannot
//  mint duplicate rows with different chat UUIDs for the same person.
//

import CoreData
import Foundation

extension Chat {

    /// Policy when the peer `User` row is missing.
    enum MissingUserPolicy {
        /// Create a minimal contact User (incoming message / engine paths).
        case createContact
        /// Do not create — return nil (BackgroundFetch must not bootstrap unknowns).
        case requireExisting
    }

    struct FindOrCreateResult {
        let chat: Chat
        let created: Bool
    }

    // MARK: - Public API

    /// Find the chat for an existing `User`, or create one.
    /// Call only on the context’s queue. Does not save.
    @discardableResult
    static func findOrCreate(
        for user: User,
        in context: NSManagedObjectContext,
        touchLastMessageTimeOnCreate: Bool = false,
        collapseDuplicates: Bool = true
    ) -> FindOrCreateResult {
        let userId = user.id
        if let existing = findBestChat(forUserId: userId, in: context, collapseDuplicates: collapseDuplicates) {
            return FindOrCreateResult(chat: existing, created: false)
        }

        let chat = makeChat(for: user, in: context, touchLastMessageTime: touchLastMessageTimeOnCreate)
        Log.debug(
            "Chat.findOrCreate: created chat \(chat.id.prefix(8))… for user \(userId.prefix(8))…",
            category: "ChatStore"
        )
        return FindOrCreateResult(chat: chat, created: true)
    }

    /// Find or create by peer server user id. Optional user bootstrap.
    /// Call only on the context’s queue. Does not save.
    /// - Returns: `nil` only when `missingUserPolicy == .requireExisting` and no User row.
    @discardableResult
    static func findOrCreate(
        forUserId userId: String,
        in context: NSManagedObjectContext,
        missingUserPolicy: MissingUserPolicy = .createContact,
        touchLastMessageTimeOnCreate: Bool = false,
        collapseDuplicates: Bool = true
    ) throws -> FindOrCreateResult? {
        if let existing = findBestChat(forUserId: userId, in: context, collapseDuplicates: collapseDuplicates) {
            return FindOrCreateResult(chat: existing, created: false)
        }

        let user: User
        if let found = try findUser(id: userId, in: context) {
            user = found
        } else {
            switch missingUserPolicy {
            case .requireExisting:
                return nil
            case .createContact:
                user = makeMinimalUser(id: userId, in: context)
            }
        }

        let chat = makeChat(for: user, in: context, touchLastMessageTime: touchLastMessageTimeOnCreate)
        Log.debug(
            "Chat.findOrCreate: created chat \(chat.id.prefix(8))… for user \(userId.prefix(8))…",
            category: "ChatStore"
        )
        return FindOrCreateResult(chat: chat, created: true)
    }

    /// Lookup only — no create. Prefer most recently active chat if duplicates exist.
    static func findExisting(
        forUserId userId: String,
        in context: NSManagedObjectContext,
        collapseDuplicates: Bool = false
    ) -> Chat? {
        findBestChat(forUserId: userId, in: context, collapseDuplicates: collapseDuplicates)
    }

    // MARK: - Internals

    private static func findUser(id: String, in context: NSManagedObjectContext) throws -> User? {
        let req = User.fetchRequest()
        req.fetchLimit = 1
        var predicates: [NSPredicate] = [NSPredicate(format: "id == %@", id)]
        if let owner = req.predicate {
            predicates.insert(owner, at: 0)
        }
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return try context.fetch(req).first
    }

    private static func fetchChats(forUserId userId: String, in context: NSManagedObjectContext) -> [Chat] {
        let req = Chat.fetchRequest()
        var predicates: [NSPredicate] = [NSPredicate(format: "otherUser.id == %@", userId)]
        if let owner = req.predicate {
            predicates.insert(owner, at: 0)
        }
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return (try? context.fetch(req)) ?? []
    }

    /// Prefer the chat with the newest activity / most messages; optionally merge orphans into it.
    private static func findBestChat(
        forUserId userId: String,
        in context: NSManagedObjectContext,
        collapseDuplicates: Bool
    ) -> Chat? {
        let chats = fetchChats(forUserId: userId, in: context)
        guard !chats.isEmpty else { return nil }

        if chats.count == 1 {
            return chats[0]
        }

        let winner = selectBestChat(among: chats)
        let losers = chats.filter { $0.objectID != winner.objectID }

        Log.info(
            "Chat.findOrCreate: \(chats.count) chats for user \(userId.prefix(8))… — keeping \(winner.id.prefix(8))…",
            category: "ChatStore"
        )

        if collapseDuplicates {
            collapse(losers: losers, into: winner, in: context)
        }
        return winner
    }

    private static func selectBestChat(among chats: [Chat]) -> Chat {
        chats.max { a, b in
            let ta = a.lastMessageTime ?? .distantPast
            let tb = b.lastMessageTime ?? .distantPast
            if ta != tb { return ta < tb }
            let ca = (a.messages as? Set<Message>)?.count ?? 0
            let cb = (b.messages as? Set<Message>)?.count ?? 0
            if ca != cb { return ca < cb }
            // Stable fallback: keep lexicographically smaller id
            return a.id > b.id
        }!
    }

    private static func collapse(losers: [Chat], into winner: Chat, in context: NSManagedObjectContext) {
        for loser in losers {
            if let messages = loser.messages as? Set<Message> {
                for message in messages {
                    message.chat = winner
                }
            }
            // Saturating add for Int16 unread
            let sum = Int(winner.unreadCount) + Int(loser.unreadCount)
            winner.unreadCount = Int16(clamping: min(sum, Int(Int16.max)))

            if let lt = loser.lastMessageTime,
               lt > (winner.lastMessageTime ?? .distantPast) {
                winner.lastMessageTime = lt
                winner.lastMessageText = loser.lastMessageText
            }
            if winner.isPinned || loser.isPinned { winner.isPinned = true }
            // Preserve mute if either row was muted.
            if loser.isMuted { winner.isMuted = true }

            let orphanId = loser.id
            context.delete(loser)
            Log.info(
                "Chat.findOrCreate: collapsed duplicate chat \(orphanId.prefix(8))… → \(winner.id.prefix(8))…",
                category: "ChatStore"
            )
        }
    }

    private static func makeChat(
        for user: User,
        in context: NSManagedObjectContext,
        touchLastMessageTime: Bool
    ) -> Chat {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        chat.unreadCount = 0
        chat.isPinned = false
        chat.isMuted = false
        if touchLastMessageTime {
            chat.lastMessageTime = Date()
        }
        return chat
    }

    private static func makeMinimalUser(id: String, in context: NSManagedObjectContext) -> User {
        let user = User(context: context)
        user.id = id
        user.username = ""
        user.displayName = DisplayNameGenerator.generate(from: id)
        user.isSharingWithMe = false
        user.isBlocked = false
        user.amISharingWith = false
        user.isContact = true
        user.addedAt = Date()
        Log.debug("Chat.findOrCreate: created minimal user \(id.prefix(8))…", category: "ChatStore")
        return user
    }
}
