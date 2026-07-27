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
    /// `stale_init_drop` (incoming msgNum=0) and the outgoing buffer stop deadlocking on a
    /// lost SESSION_RESET_INIT / lost ping (persistent-transport case, e.g. flaky iPad path).
    /// Past the window the Rust core converges the peer's re-init and new sends flow normally
    /// (exactly what `MessageRetryManager` force-retry already proves works).
    private let confirmWindow: TimeInterval = 75

    // MARK: - Mutations (called by SessionCoordinator)

    func markPending(_ userId: String) {
        pendingSince[userId] = Date()
        Log.info("SESSION_CONFIRM[pending]: \(userId.prefix(8))… — waiting for RESPONDER session_ready (window \(Int(confirmWindow))s)", category: "SessionConfirm")
    }

    func markConfirmed(_ userId: String) {
        guard pendingSince.removeValue(forKey: userId) != nil else { return }
        Log.info("SESSION_CONFIRM[confirmed]: \(userId.prefix(8))… — RESPONDER acknowledged", category: "SessionConfirm")
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
        guard pendingSince.removeValue(forKey: userId) != nil else { return false }
        Log.info("SESSION_CONFIRM[watchdog_giveup]: \(userId.prefix(8))… — confirm window exhausted, releasing gate + flushing", category: "SessionConfirm")
        return true
    }

    // MARK: - Query (called by ChatViewModel)

    /// Returns true when the INITIATOR session for this peer is awaiting `session_ready`
    /// **and** the confirm window has not elapsed. ChatViewModel uses this to buffer outgoing
    /// messages as `.queued`; MessageRouter uses it to drop the peer's stale msgNum=0. Once the
    /// window passes without confirmation the entry self-expires so neither guard can deadlock.
    func isPending(_ userId: String) -> Bool {
        let since = pendingSince[userId]
        // Single tested authority for the TTL decision (harness-covered).
        guard SessionReducer.isConfirmBuffering(pendingSince: since, now: Date(), confirmWindow: confirmWindow) else {
            if since != nil {
                pendingSince.removeValue(forKey: userId)
                Log.info("SESSION_CONFIRM[window_expired]: \(userId.prefix(8))… — no session_ready in \(Int(confirmWindow))s, releasing gate (peer re-init will now converge; buffered sends drain via retry)", category: "SessionConfirm")
            }
            return false
        }
        return true
    }
}
