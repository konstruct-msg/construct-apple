//
//  DuplicateChats.swift
//  Construct Messenger
//
//  One chat per peer, for rows written before Core Data could hold that. Until 2026-10-12 every
//  received message merged its peer's duplicates on the way in (`Chat.findOrCreate`); the message
//  path has no managed chat since, `CoreDataChatStore.insert` adds none, and what older builds
//  left is merged once per launch here. Goes with Core Data at step 5 — the crate's chats have a
//  unique index on the peer.
//

import CoreData
import Foundation

enum DuplicateChats {

    /// Merges every peer's duplicate chats into the one `kept(among:)` names: messages move to it,
    /// unread counts add up, the newest preview and a pin survive. Saves when it merged anything;
    /// returns how many chats it removed.
    @discardableResult
    static func merge(in context: NSManagedObjectContext) -> Int {
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "otherUser != nil")
        guard let rows = try? context.fetch(req) else { return 0 }
        let byPeer = Dictionary(grouping: rows) { $0.otherUser?.id ?? "" }
        var removed = 0
        for (peerId, chats) in byPeer where chats.count > 1 {
            let winner = kept(among: chats)
            for loser in chats where loser.objectID != winner.objectID {
                for message in (loser.messages as? Set<Message>) ?? [] {
                    message.chat = winner
                }
                winner.unreadCount = Int16(clamping: Int(winner.unreadCount) + Int(loser.unreadCount))
                if let time = loser.lastMessageTime, time > (winner.lastMessageTime ?? .distantPast) {
                    winner.lastMessageTime = time
                    winner.lastMessageText = loser.lastMessageText
                }
                if loser.isPinned { winner.isPinned = true }
                context.delete(loser)
                removed += 1
            }
            Log.info("Merged \(chats.count) chats for \(peerId.prefix(8))… into \(winner.id.prefix(8))…", category: "Persistence")
        }
        guard removed > 0 else { return 0 }
        do {
            try context.save()
        } catch {
            Log.error("Duplicate chats not merged: \(error)", category: "Persistence")
            context.rollback()
            return 0
        }
        return removed
    }

    /// Among duplicates, the one kept: newest activity, then most messages, then the smaller id.
    /// `CoreDataChatStore` reads by it, so a read before the merge and the merge agree on the id.
    static func kept(among chats: [Chat]) -> Chat {
        chats.max { a, b in
            let ta = a.lastMessageTime ?? .distantPast
            let tb = b.lastMessageTime ?? .distantPast
            if ta != tb { return ta < tb }
            let ca = a.messages?.count ?? 0
            let cb = b.messages?.count ?? 0
            if ca != cb { return ca < cb }
            return a.id > b.id
        }!
    }
}
