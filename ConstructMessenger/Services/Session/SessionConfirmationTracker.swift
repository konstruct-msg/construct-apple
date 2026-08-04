//
//  SessionConfirmationTracker.swift
//  Construct Messenger
//
//  Tracks which INITIATOR sessions are "unconfirmed" — i.e. a session ping was sent
//  but no __session_ready__ has been received from the RESPONDER yet.
//
//  When a session is unconfirmed, ChatViewModel saves outgoing messages as `.queued`
//  instead of encrypting and sending immediately. Once session_ready arrives (via
//  SessionCoordinator), queued messages are flushed through MessageRetryManager.
//
//  Thread-safety: all mutations happen on @MainActor via SessionCoordinator.
//

import Foundation

@MainActor
final class SessionConfirmationTracker {

    static let shared = SessionConfirmationTracker()
    private init() {}

    /// Peers awaiting `session_ready`, mapped to the instant `markPending` was called.
    /// Time-bounded (see `confirmWindow`): the flag is a *hint* to buffer, never a permanent gate.
    private var pendingSince: [String: Date] = [:]

    /// How long the confirm buffer holds before it self-releases when no `session_ready`
    /// (or ping) ever arrives. The tie-break watchdog fires one SRI retry at 30 s, so the
    /// window spans that retry plus one more RTT/heal — then the gate opens so both the
    /// incoming hold and the outgoing buffer stop deadlocking on a
    /// lost SESSION_RESET_INIT / lost ping (persistent-transport case, e.g. flaky iPad path).
    /// This is also the upper bound on how long a held incoming message waits: nothing behind
    /// the gate is discarded any more, only delayed by at most this window.
    /// Past the window the Rust core converges the peer's re-init and new sends flow normally
    /// (exactly what `MessageRetryManager` force-retry already proves works).
    private let confirmWindow: TimeInterval = 75

    // MARK: - Mutations (called by SessionCoordinator)

    func markPending(_ userId: String) {
        pendingSince[userId] = Date()
        Log.info("SESSION_CONFIRM[pending]: \(userId.prefix(8))… — waiting for RESPONDER session_ready (window \(Int(confirmWindow))s)", category: "SessionConfirm")
    }

    func markConfirmed(_ userId: String) {
        // The caller replays the hold itself, so an unsettled lapse for this peer is moot.
        lapsedUnreplayed.remove(userId)
        guard pendingSince.removeValue(forKey: userId) != nil else { return }
        Log.info("SESSION_CONFIRM[confirmed]: \(userId.prefix(8))… — RESPONDER acknowledged", category: "SessionConfirm")
    }

    // MARK: - Unsettled lapses

    /// Peers whose gate fell via the **lazy TTL inside `isPending`** rather than via an explicit
    /// release, and whose held incoming messages therefore have not been replayed yet.
    ///
    /// Both explicit releases (peer ack, watchdog give-up) replay the hold as part of dropping the
    /// gate. The lazy TTL cannot: it fires inside a query, from whatever call site happened to ask,
    /// with no context to route with. And it *wins the race* — observed 2026-08-04 in build 575,
    /// where `isPending` expired the entry at 18:36:37 before the 30 s watchdog tick could return
    /// `.giveUp`, so the `.giveUp` replay never ran and two held peer inits sat in the buffer with
    /// the stream cursor deferred behind them. Recording the lapse lets the next router pass settle
    /// what the query could not.
    private var lapsedUnreplayed: Set<String> = []

    /// Claim an unsettled lapse for `userId`. True exactly once per lapse — the caller must then
    /// replay that peer's hold.
    @discardableResult
    func consumeLapse(_ userId: String) -> Bool {
        lapsedUnreplayed.remove(userId) != nil
    }

    // MARK: - Tie-break watchdog (called by SessionCoordinator's re-arming watchdog)

    /// Watchdog tick decision for this peer, delegating to the reducer's pure policy: `.retry` while
    /// within the confirm window, `.giveUp` once it has lapsed. Read-only (does not mutate the map).
    func watchdogTick(_ userId: String, now: Date = Date()) -> SessionReducer.WatchdogTick {
        SessionReducer.tieBreakWatchdogTick(pendingSince: pendingSince[userId], now: now, confirmWindow: confirmWindow)
    }

    /// Explicitly release a lapsed confirm buffer on watchdog give-up (proactive, vs the lazy TTL
    /// expiry in `isPending`). Returns whether an entry was actually pending.
    @discardableResult
    func releaseLapsed(_ userId: String) -> Bool {
        // This path replays the hold itself.
        lapsedUnreplayed.remove(userId)
        guard pendingSince.removeValue(forKey: userId) != nil else { return false }
        Log.info("SESSION_CONFIRM[watchdog_giveup]: \(userId.prefix(8))… — confirm window exhausted, releasing gate + flushing", category: "SessionConfirm")
        return true
    }

    // MARK: - Query (called by ChatViewModel)

    /// Returns true when the INITIATOR session for this peer is awaiting `session_ready`
    /// **and** the confirm window has not elapsed. ChatViewModel uses this to buffer outgoing
    /// messages as `.queued`; MessageRouter uses it to hold the peer's msgNum=0 and to suppress a
    /// teardown on a decrypt failure it caused itself. Once the window passes without confirmation
    /// the entry self-expires so neither guard can deadlock.
    #if DEBUG
    /// Backdate the pending stamp past the confirm window so a test can drive the TTL branch
    /// without sleeping 75 s. Only the stamp is touched — the expiry itself still runs in
    /// `isPending`, which is the behaviour under test.
    func expireForTesting(_ userId: String) {
        guard pendingSince[userId] != nil else { return }
        pendingSince[userId] = Date().addingTimeInterval(-(confirmWindow + 1))
    }
    #endif

    func isPending(_ userId: String) -> Bool {
        let since = pendingSince[userId]
        // Single tested authority for the TTL decision (harness-covered).
        guard SessionReducer.isConfirmBuffering(pendingSince: since, now: Date(), confirmWindow: confirmWindow) else {
            if since != nil {
                pendingSince.removeValue(forKey: userId)
                // Held incoming messages still need replaying, and this call site cannot do it —
                // see `lapsedUnreplayed`. Mark it so the next router pass settles it.
                lapsedUnreplayed.insert(userId)
                Log.info("SESSION_CONFIRM[window_expired]: \(userId.prefix(8))… — no session_ready in \(Int(confirmWindow))s, releasing gate (peer re-init will now converge; buffered sends drain via retry, held incoming replays on the next pass)", category: "SessionConfirm")
            }
            return false
        }
        return true
    }
}
