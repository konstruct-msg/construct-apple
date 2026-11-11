//
//  StreamCursorTracker.swift
//  Construct Messenger
//
//  The Redis-stream resume cursor (`StreamCursorStore`, sent as SubscribeRequest.since_cursor —
//  the position the server trims the offline stream up to).
//
//  THE INVARIANT: the committed cursor never advances past a message that is not yet durably
//  handled. Advancing past a message tells the server to delete it (XTRIM ≤ cursor); if that
//  message was only waiting in the core's in-memory queue (no session yet) and the app died, it
//  would be lost forever.
//
//  The rule is the core's (construct-rules `stream_cursor`, `StreamCursorState`), one for every
//  client: entries in arrival order, the cursor over the longest contiguous run of resolved entries
//  at the front, never past a pending or deferred one. It was written here first (2026-06-16) and
//  ported to Android; construct-client's third copy had drifted and stored the cursor of whichever
//  message finished last (todo 299). What stays here: persisting the cursor, and the log lines.
//
//  Missing a resolve() degrades to a STALL (cursor stops advancing → server re-delivers, client
//  dedups) — a safe, observable failure mode, never message loss. The stall self-heals on the next
//  reconnect: re-delivery from the un-advanced cursor re-tracks the entries.
//

import Foundation

@MainActor
final class StreamCursorTracker {
    static let shared = StreamCursorTracker()

    /// Terminal disposition reported by the incoming-message pipeline for a tracked message.
    enum Outcome {
        /// Durably handled (persisted / control-handled / given up) → may advance the cursor.
        case durable
        /// Queued in-memory pending session init (or a transient retry) → hold the watermark
        /// until the message is later drained-and-persisted or discarded.
        case deferred
        /// Not this caller's message to resolve (duplicate already in flight, not-ready) →
        /// leave the entry untouched so the owning path resolves it.
        case skip

        fileprivate var core: StreamCursorOutcome {
            switch self {
            case .durable: return .durable
            case .deferred: return .deferred
            case .skip: return .skip
            }
        }
    }

    private let entries = StreamCursorState()

    /// Persists the committed cursor. Injected for tests.
    private let persist: (String) -> Void

    init(persist: @escaping (String) -> Void = { StreamCursorStore.save($0) }) {
        self.persist = persist
    }

    /// Drop all in-flight tracking. Called on each (re)connect: the persisted cursor in
    /// `StreamCursorStore` is the source of truth for since_cursor, and re-delivery from there
    /// re-tracks any un-advanced entries.
    func reset() {
        entries.reset()
    }

    /// Record a stream entry in arrival order. Dedups by message id; ignores empties.
    func track(messageId: String, cursor: String) {
        entries.track(messageId: messageId, cursor: cursor, nowMs: Self.nowMs())
    }

    /// Report the terminal outcome for a tracked message and advance the committed cursor over
    /// the resulting contiguous-resolved prefix. No-op for an untracked id (e.g. backfill
    /// messages, which carry no stream cursor). Returns the new committed cursor, or nil.
    @discardableResult
    func report(messageId: String, _ outcome: Outcome) -> String? {
        let moved = entries.report(messageId: messageId, outcome: outcome.core)
        if let moved { persist(moved) }
        return moved
    }

    /// Force-resolve a (possibly deferred) message — used when a queued message is finally
    /// drained-and-persisted or discarded. Equivalent to `report(.durable)`.
    @discardableResult
    func resolve(messageId: String) -> String? {
        report(messageId: messageId, .durable)
    }

    /// Abandon everything currently held and jump the committed cursor to the furthest entry the
    /// server has delivered on this connection. Returns the new cursor, or nil if nothing is held.
    ///
    /// **This deliberately breaks the invariant at the top of this file**, and it is the only thing
    /// here that does. Advancing past an unresolved entry tells the server to trim a message we
    /// never persisted, which is message loss — the exact outcome the contiguous-prefix rule
    /// exists to prevent. So it is never automatic: no timer calls it, no heuristic calls it, and
    /// it must not acquire one. A stall is safe by design, and the correct fix for any given stall
    /// is to resolve whatever is stuck.
    ///
    /// It exists because "safe" is not the same as "recoverable". On 2026-08-20 a device had been
    /// resuming from 31 July for three weeks: the head entry belonged to an account the server had
    /// deleted, so nothing would ever resolve it, and every reconnect re-read the whole backlog
    /// behind it. The only way out was reinstalling the app, which also destroys the identity —
    /// a worse loss than the one this risks, and the user reached for it because nothing else
    /// existed. That cause is fixed (`VanishedPeerStore`); the next unresolvable head will have a
    /// different one, and the escape hatch should already be there when it does.
    ///
    /// Exposed only as an explicit action in Diagnostics, worded as what it is: skipping whatever
    /// has piled up, at the risk of dropping messages that were never delivered.
    @discardableResult
    func skipHeldBacklog() -> String? {
        guard let skipped = entries.skipHeldBacklog() else { return nil }
        persist(skipped.cursor)
        let head = skipped.head.map {
            "\($0.messageId.prefix(8))… (\(Self.name($0.hold)), \(Int(Self.age(of: $0)))s)"
        }
        Log.error(
            "STREAM_CURSOR[skipped]: user skipped \(skipped.held) held entr\(skipped.held == 1 ? "y" : "ies") — cursor forced to \(skipped.cursor); head was \(head ?? "none"). Anything unresolved in that range is now unrecoverable.",
            category: "StreamReplay"
        )
        return skipped.cursor
    }

    /// The entry currently holding the committed cursor back, if any.
    ///
    /// The stall above is safe — the server re-delivers and the client dedups — but it is not
    /// free, and it was silent. The server trims and resumes from the committed position, so one
    /// entry stuck at the head means every reconnect re-reads the entire backlog behind it. That
    /// is invisible with two testers and ruinous with a thousand users, so the head entry names
    /// itself instead of being inferred from a redelivery count. See `StreamReplayAudit`.
    func headBlocker() -> (messageId: String, state: String, age: TimeInterval)? {
        guard let head = entries.headBlocker() else { return nil }
        return (head.messageId, Self.name(head.hold), Self.age(of: head))
    }

    private static func name(_ hold: StreamCursorHold) -> String {
        switch hold {
        case .pending: return "pending"
        case .deferred: return "deferred"
        }
    }

    private static func age(of head: StreamCursorBlocker) -> TimeInterval {
        max(0, Double(nowMs() - head.trackedAtMs) / 1000)
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Test hooks

    /// Number of entries still in flight (pending or deferred or resolved-but-blocked).
    var inFlightCount: Int { Int(entries.inFlight()) }
}
