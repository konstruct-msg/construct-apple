//
//  ReactionStore.swift
//  Construct Messenger
//
//  The reactions as a repository (LOCAL_STORE_MIGRATION_PLAN, messages B3): one row per
//  (message, reactor), values in and out. What a reaction does to that row — newer wins, a remove
//  clears, a refused tap is put back — is `Reactions`, over any store. Core Data answers today;
//  `LocalStore` takes over with `upsert_reaction`, `reactions`, `delete_reaction` and
//  `expire_reactions` (construct-core 0.39.0: orphans only).
//
//  Ids are lowercased at this seam, as the crate stores them. Reads compare without case, so a row
//  written before that still answers.
//

import Foundation
import CoreData

struct ReactionRecord: Equatable, Sendable {
    let targetMessageId: String
    let reactorUserId: String
    var emoji: String
    /// The reactor's clock, which orders two reactions by one reactor.
    var timestampMs: Int64
    /// When this device stored it — what an orphan's wait is counted from.
    var receivedAt: Date?
}

protocol ReactionStore: Sendable {
    func reaction(on targetMessageId: String, by reactorUserId: String) throws -> ReactionRecord?
    /// A message's reactions, oldest first.
    func reactions(on targetMessageId: String) throws -> [ReactionRecord]
    /// Insert, or replace the reactor's row on that message.
    func upsert(_ reaction: ReactionRecord) throws
    func delete(on targetMessageId: String, by reactorUserId: String) throws
    /// Forget reactions whose message is not here and which were received at or before `cutoff`.
    /// A reaction on a held message is never expired, however old. Returns how many went.
    @discardableResult func expireOrphans(receivedAtOrBefore cutoff: Date) throws -> Int
}

/// `Reaction` rows. Each call runs on a fresh background context, for the reason
/// `CoreDataPeerDeviceStore` gives.
final class CoreDataReactionStore: ReactionStore, @unchecked Sendable {

    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func reaction(on targetMessageId: String, by reactorUserId: String) throws -> ReactionRecord? {
        try run { context in
            try Self.row(targetMessageId, reactorUserId, in: context).map(ReactionRecord.init(row:))
        }
    }

    func reactions(on targetMessageId: String) throws -> [ReactionRecord] {
        try run { context in
            let req = Reaction.fetchRequest()
            req.predicate = NSPredicate(format: "targetMessageId ==[c] %@", targetMessageId)
            req.sortDescriptors = [NSSortDescriptor(key: "timestampMs", ascending: true)]
            return try context.fetch(req).map(ReactionRecord.init(row:))
        }
    }

    func upsert(_ reaction: ReactionRecord) throws {
        try run { context in
            let row = try Self.row(reaction.targetMessageId, reaction.reactorUserId, in: context)
                ?? Reaction(context: context)
            row.targetMessageId = reaction.targetMessageId.lowercased()
            row.reactorUserId = reaction.reactorUserId.lowercased()
            row.emoji = reaction.emoji
            row.timestampMs = reaction.timestampMs
            row.receivedAt = reaction.receivedAt
            try context.saveOrThrow(category: "Reactions")
        }
    }

    func delete(on targetMessageId: String, by reactorUserId: String) throws {
        try run { context in
            guard let row = try Self.row(targetMessageId, reactorUserId, in: context) else { return }
            context.delete(row)
            try context.saveOrThrow(category: "Reactions")
        }
    }

    func expireOrphans(receivedAtOrBefore cutoff: Date) throws -> Int {
        try run { context in
            let req = Reaction.fetchRequest()
            req.predicate = NSPredicate(format: "receivedAt != nil AND receivedAt <= %@", cutoff as NSDate)
            let orphans = try context.fetch(req).filter { try !Self.messageExists($0.targetMessageId, in: context) }
            guard !orphans.isEmpty else { return 0 }
            orphans.forEach(context.delete)
            try context.saveOrThrow(category: "Reactions")
            return orphans.count
        }
    }

    private static func row(_ target: String, _ reactor: String, in context: NSManagedObjectContext) throws -> Reaction? {
        let req = Reaction.fetchRequest()
        req.predicate = NSPredicate(
            format: "targetMessageId ==[c] %@ AND reactorUserId ==[c] %@", target, reactor
        )
        req.fetchLimit = 1
        return try context.fetch(req).first
    }

    private static func messageExists(_ id: String, in context: NSManagedObjectContext) throws -> Bool {
        let req = Message.fetchRequest()
        req.predicate = NSPredicate(format: "id ==[c] %@", id)
        req.fetchLimit = 1
        return try context.count(for: req) > 0
    }

    private func run<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = container.newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}

extension ReactionRecord {
    init(row: Reaction) {
        self.init(
            targetMessageId: row.targetMessageId, reactorUserId: row.reactorUserId,
            emoji: row.emoji, timestampMs: row.timestampMs, receivedAt: row.receivedAt
        )
    }
}
