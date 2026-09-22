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
//  **Keyed by device since 2026-09-22.** A confirmation is about a ratchet, and a ratchet is a
//  pair of devices: an account with two devices opens two sessions and the peer confirms each
//  one separately. Account-keyed, the first `session_ready` to arrive released the gate for both,
//  so user content went out on a ratchet nobody had confirmed — which is the one thing the gate
//  exists to prevent. Step 1 of `decisions/session-is-one-state-machine.md`; it was blocked until
//  §D let a sealed delivery name its sending device (`ChatMessage.senderDeviceId`).
//
//  Questions are still asked of the account, because the send path is: a message goes to every
//  device, so "may I send?" is "is **any** of them unconfirmed?".
//
//  Thread-safety: all mutations happen on @MainActor via SessionCoordinator.
//

import Foundation

@MainActor
final class SessionConfirmationTracker {

    static let shared = SessionConfirmationTracker()
    private init() {}

    /// One unconfirmed ratchet.
    private struct Pending {
        /// The account the device belongs to, so an account-shaped question can be answered
        /// without a Core Data fetch on the send path.
        let account: String
        let since: Date
    }

    /// Ratchets awaiting `session_ready`, keyed by the peer **device** they were opened with.
    ///
    /// A peer we cannot name a device for yet — first contact, before any bundle answered — is
    /// keyed by its account id instead. The two spaces cannot collide (36-char UUID against
    /// 32-char hex), and the placeholder is replaced by the real devices as soon as the init
    /// says which they are. Time-bounded (see `confirmWindow`): the flag is a *hint* to buffer,
    /// never a permanent gate.
    private var pendingSince: [String: Pending] = [:]

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

    /// Raise the gate for one ratchet, or for the account when no device can be named yet.
    ///
    /// The raise happens **before** the init runs — deliberately, so a peer that answers faster
    /// than our own continuation cannot have its `session_ready` swallowed — and at that moment
    /// the devices the init will open are not known. So a caller raises for the devices it knows
    /// and re-raises with the ones the init actually opened; the placeholder is dropped by the
    /// first device-named raise for the same account.
    func markPending(_ address: PeerAddress) {
        if address.device != nil { dropPlaceholder(for: address.account) }
        let key = address.device ?? address.account
        pendingSince[key] = Pending(account: address.account, since: Date())
        Log.info("SESSION_CONFIRM[pending]: \(address.description) — waiting for RESPONDER session_ready (window \(Int(confirmWindow))s)", category: "SessionConfirm")
    }

    /// The account-shaped placeholder, once a real device has been named for that account.
    private func dropPlaceholder(for account: String) {
        guard pendingSince.removeValue(forKey: account) != nil else { return }
        Log.info("SESSION_CONFIRM[placeholder_replaced]: \(account.prefix(8))… — the init named its devices", category: "SessionConfirm")
    }

    /// Drop the gate the peer just confirmed.
    ///
    /// **A confirmation that names no device settles the whole account.** That is the safety
    /// valve, not a shortcut: a `session_ready` arriving unsealed, or from a client that predates
    /// the sender certificate, cannot say which ratchet it is about, and a gate nothing can
    /// release is a conversation that stops sending for the length of the window. The exact case
    /// is the common one and is preferred wherever the caller has `senderDeviceId`.
    func markConfirmed(_ address: PeerAddress) {
        let keys: [String]
        if let device = address.device {
            keys = pendingSince[device] != nil ? [device] : []
        } else {
            keys = pendingSince.filter { $0.value.account == address.account }.map(\.key)
        }
        // The caller replays the hold itself, so an unsettled lapse for this peer is moot.
        lapsedUnreplayed.remove(address.account)
        guard !keys.isEmpty else { return }
        for key in keys { pendingSince.removeValue(forKey: key) }
        Log.info(
            "SESSION_CONFIRM[confirmed]: \(address.description) — RESPONDER acknowledged (\(keys.count) ratchet(s))",
            category: "SessionConfirm"
        )
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
    ///
    /// Kept per **account**: a replay is a walk over one conversation's held messages, and there
    /// is one conversation per account however many ratchets it holds.
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
    ///
    /// The **oldest** unconfirmed ratchet of the account decides. One watchdog serves the whole
    /// conversation, so giving up on the youngest would leave the one that has waited longest
    /// still held.
    func watchdogTick(_ userId: String, now: Date = Date()) -> SessionReducer.WatchdogTick {
        SessionReducer.tieBreakWatchdogTick(pendingSince: oldestPending(of: userId), now: now, confirmWindow: confirmWindow)
    }

    private func oldestPending(of account: String) -> Date? {
        pendingSince.values.filter { $0.account == account }.map(\.since).min()
    }

    /// Explicitly release a lapsed confirm buffer on watchdog give-up (proactive, vs the lazy TTL
    /// expiry in `isPending`). Returns whether an entry was actually pending.
    @discardableResult
    func releaseLapsed(_ userId: String) -> Bool {
        // This path replays the hold itself.
        lapsedUnreplayed.remove(userId)
        let keys = pendingSince.filter { $0.value.account == userId }.map(\.key)
        guard !keys.isEmpty else { return false }
        for key in keys { pendingSince.removeValue(forKey: key) }
        Log.info("SESSION_CONFIRM[watchdog_giveup]: \(userId.prefix(8))… — confirm window exhausted, releasing \(keys.count) gate(s) + flushing", category: "SessionConfirm")
        return true
    }

    // MARK: - Query (called by ChatViewModel)

    #if DEBUG
    /// Backdate every pending stamp of this peer past the confirm window so a test can drive the
    /// TTL branch without sleeping 75 s. Only the stamp is touched — the expiry itself still runs
    /// in `isPending`, which is the behaviour under test.
    func expireForTesting(_ userId: String) {
        for (key, entry) in pendingSince where entry.account == userId {
            pendingSince[key] = Pending(account: entry.account, since: Date().addingTimeInterval(-(confirmWindow + 1)))
        }
    }
    #endif

    /// Returns true when **any** ratchet with this peer is awaiting `session_ready` and its
    /// confirm window has not elapsed.
    ///
    /// Asked of the account because the send path is account-shaped: one message becomes a copy
    /// per device, so a single unconfirmed ratchet is enough to buffer — sending would put user
    /// content on it. ChatViewModel uses this to buffer outgoing messages as `.queued`;
    /// MessageRouter uses it to hold the peer's msgNum=0 and to suppress a teardown on a decrypt
    /// failure it caused itself. Once the window passes without confirmation the entry
    /// self-expires so neither guard can deadlock.
    func isPending(_ userId: String) -> Bool {
        let now = Date()
        var stillPending = false
        var lapsed = false
        for (key, entry) in pendingSince where entry.account == userId {
            // Single tested authority for the TTL decision (harness-covered).
            if SessionReducer.isConfirmBuffering(pendingSince: entry.since, now: now, confirmWindow: confirmWindow) {
                stillPending = true
            } else {
                pendingSince.removeValue(forKey: key)
                lapsed = true
            }
        }
        if lapsed, !stillPending {
            // Held incoming messages still need replaying, and this call site cannot do it —
            // see `lapsedUnreplayed`. Mark it so the next router pass settles it.
            lapsedUnreplayed.insert(userId)
            Log.info("SESSION_CONFIRM[window_expired]: \(userId.prefix(8))… — no session_ready in \(Int(confirmWindow))s, releasing gate (peer re-init will now converge; buffered sends drain via retry, held incoming replays on the next pass)", category: "SessionConfirm")
        }
        return stillPending
    }
}
