//
//  StreamCursorTracker.swift
//  Construct Messenger
//
//  ACK-driven advance of the Redis-stream resume cursor (`StreamCursorStore`, sent as
//  SubscribeRequest.since_cursor — the position the server trims the offline stream up to).
//
//  THE INVARIANT: the committed cursor must never advance past a message that is not yet
//  durably handled. Advancing past a message tells the server to delete it (XTRIM ≤ cursor);
//  if that message was only sitting in the in-memory PendingSessionQueue (no session yet)
//  and the app died, it would be lost forever. (The catastrophic trim-on-read loss is already
//  fixed server-side; this closes the remaining received-but-not-durable window.)
//
//  Model: a FIFO of stream entries in arrival order. An entry is resolved once its message
//  reaches a durable terminal (persisted to Core Data, or a control message fully handled,
//  or definitively given up). The committed cursor advances over the longest *contiguous*
//  run of resolved entries from the front — never skipping a still-pending/deferred one.
//  A deferred (queued-for-session-init) entry holds the watermark until it is later drained
//  (re-routed → durable) or discarded (give-up), both of which resolve it.
//
//  Missing a resolve() degrades to a STALL (cursor stops advancing → server re-delivers,
//  client dedups) — a safe, observable failure mode, never message loss. The stall self-heals
//  on the next reconnect: re-delivery from the un-advanced cursor re-tracks the entries.
//
//  Pure and synchronous; the only side effect is persisting the committed cursor, injected so
//  it is unit-testable without touching UserDefaults.
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
    }

    private enum State: String { case pending, deferred, resolved }
    private struct Entry {
        let messageId: String
        let cursor: String
        var state: State
        let trackedAt: Date
    }

    private var entries: [Entry] = []
    private var committed: String?

    /// Persists the committed cursor. Injected for tests.
    private let persist: (String) -> Void

    init(persist: @escaping (String) -> Void = { StreamCursorStore.save($0) }) {
        self.persist = persist
    }

    /// Drop all in-flight tracking. Called on each (re)connect: the persisted cursor in
    /// `StreamCursorStore` is the source of truth for since_cursor, and re-delivery from there
    /// re-tracks any un-advanced entries.
    func reset() {
        entries.removeAll()
        committed = nil
    }

    /// Record a stream entry in arrival order. Dedups by message id; ignores empties.
    func track(messageId: String, cursor: String) {
        guard !messageId.isEmpty, !cursor.isEmpty else { return }
        guard !entries.contains(where: { $0.messageId == messageId }) else { return }
        entries.append(Entry(messageId: messageId, cursor: cursor, state: .pending, trackedAt: Date()))
    }

    /// Report the terminal outcome for a tracked message and advance the committed cursor over
    /// the resulting contiguous-resolved prefix. No-op for an untracked id (e.g. backfill
    /// messages, which carry no stream cursor). Returns the new committed cursor, or nil.
    @discardableResult
    func report(messageId: String, _ outcome: Outcome) -> String? {
        guard let idx = entries.firstIndex(where: { $0.messageId == messageId }) else { return nil }
        switch outcome {
        case .durable:
            entries[idx].state = .resolved
        case .deferred:
            if entries[idx].state == .pending { entries[idx].state = .deferred }
        case .skip:
            break
        }
        return advance()
    }

    /// Force-resolve a (possibly deferred) message — used when a queued message is finally
    /// drained-and-persisted or discarded. Equivalent to `report(.durable)`.
    @discardableResult
    func resolve(messageId: String) -> String? {
        report(messageId: messageId, .durable)
    }

    private func advance() -> String? {
        var newCommitted: String?
        while let first = entries.first, first.state == .resolved {
            newCommitted = first.cursor
            entries.removeFirst()
        }
        guard let c = newCommitted, c != committed else { return nil }
        committed = c
        persist(c)
        return c
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
        guard let furthest = entries.last else { return nil }
        let held = entries.count
        let blocker = headBlocker()
        entries.removeAll()
        committed = furthest.cursor
        persist(furthest.cursor)
        Log.error(
            "STREAM_CURSOR[skipped]: user skipped \(held) held entr\(held == 1 ? "y" : "ies") — cursor forced to \(furthest.cursor); head was \(blocker.map { "\($0.messageId.prefix(8))… (\($0.state), \(Int($0.age))s)" } ?? "none"). Anything unresolved in that range is now unrecoverable.",
            category: "StreamReplay"
        )
        return furthest.cursor
    }

    /// The entry currently holding the committed cursor back, if any.
    ///
    /// The stall above is safe — the server re-delivers and the client dedups — but it is not
    /// free, and it was silent. The server trims and resumes from the committed position, so one
    /// entry stuck at the head means every reconnect re-reads the entire backlog behind it. That
    /// is invisible with two testers and ruinous with a thousand users, so the head entry names
    /// itself instead of being inferred from a redelivery count. See `StreamReplayAudit`.
    func headBlocker() -> (messageId: String, state: String, age: TimeInterval)? {
        guard let first = entries.first, first.state != .resolved else { return nil }
        return (first.messageId, first.state.rawValue, Date().timeIntervalSince(first.trackedAt))
    }

    // MARK: - Test hooks

    /// Number of entries still in flight (pending or deferred or resolved-but-blocked).
    var inFlightCount: Int { entries.count }
}
