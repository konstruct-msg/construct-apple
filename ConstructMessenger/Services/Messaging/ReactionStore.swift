//
//  ReactionStore.swift
//  Construct Messenger
//
//  Persists ReactionReducer decisions. A reaction is never a Message row.
//  Orphans (target not yet stored) stay until the target arrives or the 7-day TTL.
//

import Foundation
import CoreData

enum ReactionStore {

    static let didChange = Notification.Name("construct.reaction.didChange")

    /// Envelope `ChatMessage.timestamp` is Unix seconds (see `Date.fromRemoteTimestamp`).
    /// Values already in milliseconds (13+ digits) pass through.
    static func envelopeTimestampMs(_ unix: UInt64) -> Int64 {
        guard unix > 0 else { return 0 }
        if unix > 1_000_000_000_000 { return Int64(unix) }
        return Int64(unix) &* 1000
    }

    static func row(
        targetMessageId: String,
        reactorUserId: String,
        in context: NSManagedObjectContext
    ) -> Reaction? {
        let target = targetMessageId.lowercased()
        let reactor = reactorUserId.lowercased()
        let request = Reaction.fetchRequest()
        request.predicate = NSPredicate(
            format: "targetMessageId ==[c] %@ AND reactorUserId == %@",
            target, reactor
        )
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    static func reactions(
        on targetMessageId: String,
        in context: NSManagedObjectContext
    ) -> [Reaction] {
        let request = Reaction.fetchRequest()
        request.predicate = NSPredicate(format: "targetMessageId ==[c] %@", targetMessageId.lowercased())
        request.sortDescriptors = [NSSortDescriptor(key: "timestampMs", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// Fetch existing row → reducer → upsert/delete. Saves the context.
    /// `nowMs` is injected so orphan TTL is testable.
    @discardableResult
    static func applyIncoming(
        targetMessageId: String,
        reactorUserId: String,
        actionRawValue: Int,
        emoji: String,
        payloadTimestampMs: Int64,
        fallbackTimestampMs: Int64,
        nowMs: Int64,
        in context: NSManagedObjectContext
    ) -> ReactionReducer.Decision {
        let target = targetMessageId.lowercased()
        let reactor = reactorUserId.lowercased()
        let incoming = ReactionReducer.incoming(actionRawValue: actionRawValue, emoji: emoji)
        let existing = row(targetMessageId: target, reactorUserId: reactor, in: context)
        let existingRow = existing.map { ReactionReducer.Row(emoji: $0.emoji, timestampMs: $0.timestampMs) }
        let clock = ReactionReducer.normalizeTimestamp(
            payloadMs: payloadTimestampMs,
            fallbackMs: fallbackTimestampMs
        )
        let decision = ReactionReducer.apply(
            existing: existingRow,
            incoming: incoming,
            timestampMs: clock,
            targetMessageId: target
        )

        switch decision {
        case .set(let nextEmoji, let ts):
            let record = existing ?? Reaction(context: context)
            record.targetMessageId = target
            record.reactorUserId = reactor
            record.emoji = nextEmoji
            record.timestampMs = ts
            record.receivedAt = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)
            save(context)
        case .clear:
            if let existing {
                context.delete(existing)
                save(context)
            }
        case .keepExisting, .dropInvalid:
            break
        }

        sweepOrphans(nowMs: nowMs, in: context)
        notify(target)
        return decision
    }

    /// Undo an optimistic local write the wire refused. Not LWW — a stale
    /// timestamp would lose to the tap we are rolling back.
    static func restoreLocal(
        targetMessageId: String,
        reactorUserId: String,
        previous: ReactionReducer.Row?,
        nowMs: Int64,
        in context: NSManagedObjectContext
    ) {
        let target = targetMessageId.lowercased()
        let reactor = reactorUserId.lowercased()
        let existing = row(targetMessageId: target, reactorUserId: reactor, in: context)
        if let previous {
            let record = existing ?? Reaction(context: context)
            record.targetMessageId = target
            record.reactorUserId = reactor
            record.emoji = previous.emoji
            record.timestampMs = previous.timestampMs
            record.receivedAt = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)
            save(context)
        } else if let existing {
            context.delete(existing)
            save(context)
        }
        notify(target)
    }

    static func sweepOrphans(nowMs: Int64, in context: NSManagedObjectContext) {
        let cutoffMs = nowMs - Int64(ReactionReducer.orphanTTLSeconds * 1000)
        guard cutoffMs > 0 else { return }
        let cutoff = Date(timeIntervalSince1970: TimeInterval(cutoffMs) / 1000)
        let request = Reaction.fetchRequest()
        request.predicate = NSPredicate(format: "receivedAt != nil AND receivedAt <= %@", cutoff as NSDate)
        guard let aged = try? context.fetch(request), !aged.isEmpty else { return }

        var didDelete = false
        for reaction in aged {
            let exists = messageExists(reaction.targetMessageId, in: context)
            if ReactionReducer.shouldEvictOrphan(
                targetExists: exists,
                receivedAtMs: Int64((reaction.receivedAt ?? cutoff).timeIntervalSince1970 * 1000),
                nowMs: nowMs
            ) {
                context.delete(reaction)
                didDelete = true
            }
        }
        if didDelete {
            save(context)
        }
    }

    private static func messageExists(_ id: String, in context: NSManagedObjectContext) -> Bool {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id ==[c] %@", id)
        request.fetchLimit = 1
        return ((try? context.fetch(request).first) != nil)
    }

    private static func save(_ context: NSManagedObjectContext) {
        do {
            try context.saveOrThrow(category: "ReactionStore")
        } catch {
            context.rollback()
        }
    }

    private static func notify(_ targetMessageId: String) {
        NotificationCenter.default.post(name: didChange, object: targetMessageId)
    }
}
