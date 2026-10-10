//
//  Reactions.swift
//  Construct Messenger
//
//  What a reaction does to the stored table: ReactionReducer decides, `ReactionStore` keeps.
//  A reaction is never a Message row. Orphans (target not yet stored) stay until the target
//  arrives or the 7-day TTL.
//

import Foundation

enum Reactions {

    static let didChange = Notification.Name("construct.reaction.didChange")

    /// Envelope `ChatMessage.timestamp` is Unix seconds (see `Date.fromRemoteTimestamp`).
    /// Values already in milliseconds (13+ digits) pass through.
    static func envelopeTimestampMs(_ unix: UInt64) -> Int64 {
        guard unix > 0 else { return 0 }
        if unix > 1_000_000_000_000 { return Int64(unix) }
        return Int64(unix) &* 1000
    }

    /// Stored row → reducer → upsert/delete, then the orphan sweep.
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
        store: any ReactionStore = LocalRepositories.reactions
    ) -> ReactionReducer.Decision {
        let target = targetMessageId.lowercased()
        let reactor = reactorUserId.lowercased()
        let incoming = ReactionReducer.incoming(actionRawValue: actionRawValue, emoji: emoji)
        let existing = try? store.reaction(on: target, by: reactor)
        let clock = ReactionReducer.normalizeTimestamp(
            payloadMs: payloadTimestampMs,
            fallbackMs: fallbackTimestampMs
        )
        let decision = ReactionReducer.apply(
            existing: existing.map { ReactionReducer.Row(emoji: $0.emoji, timestampMs: $0.timestampMs) },
            incoming: incoming,
            timestampMs: clock,
            targetMessageId: target
        )

        switch decision {
        case .set(let nextEmoji, let ts):
            write(store, "apply") {
                try store.upsert(ReactionRecord(
                    targetMessageId: target, reactorUserId: reactor, emoji: nextEmoji,
                    timestampMs: ts, receivedAt: date(nowMs)
                ))
            }
        case .clear:
            if existing != nil {
                write(store, "clear") { try store.delete(on: target, by: reactor) }
            }
        case .keepExisting, .dropInvalid:
            break
        }

        sweepOrphans(nowMs: nowMs, store: store)
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
        store: any ReactionStore = LocalRepositories.reactions
    ) {
        let target = targetMessageId.lowercased()
        let reactor = reactorUserId.lowercased()
        if let previous {
            write(store, "restore") {
                try store.upsert(ReactionRecord(
                    targetMessageId: target, reactorUserId: reactor, emoji: previous.emoji,
                    timestampMs: previous.timestampMs, receivedAt: date(nowMs)
                ))
            }
        } else {
            write(store, "restore") { try store.delete(on: target, by: reactor) }
        }
        notify(target)
    }

    /// Orphans that waited out `ReactionReducer.orphanTTLSeconds`. Which reaction is an orphan is
    /// the store's to decide (`expire_reactions` in the crate): one on a held message stays.
    static func sweepOrphans(nowMs: Int64, store: any ReactionStore = LocalRepositories.reactions) {
        let cutoffMs = nowMs - Int64(ReactionReducer.orphanTTLSeconds * 1000)
        guard cutoffMs > 0 else { return }
        write(store, "sweep") { try store.expireOrphans(receivedAtOrBefore: date(cutoffMs)) }
    }

    private static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    private static func write(_ store: any ReactionStore, _ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Log.error("Reaction \(what) not stored: \(error)", category: "Reactions")
        }
    }

    private static func notify(_ targetMessageId: String) {
        NotificationCenter.default.post(name: didChange, object: targetMessageId)
    }
}
