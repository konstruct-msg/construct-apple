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

    private enum State { case pending, deferred, resolved }
    private struct Entry { let messageId: String; let cursor: String; var state: State }

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
        entries.append(Entry(messageId: messageId, cursor: cursor, state: .pending))
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

    // MARK: - Test hooks

    /// Number of entries still in flight (pending or deferred or resolved-but-blocked).
    var inFlightCount: Int { entries.count }
}
