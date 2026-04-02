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

    /// User IDs for which we sent a session ping but have not yet received session_ready.
    private var pending: Set<String> = []

    // MARK: - Mutations (called by SessionCoordinator)

    func markPending(_ userId: String) {
        pending.insert(userId)
        Log.info("🔒 SESSION_CONFIRM[pending]: \(userId.prefix(8))… — waiting for RESPONDER session_ready", category: "SessionConfirm")
    }

    func markConfirmed(_ userId: String) {
        guard pending.contains(userId) else { return }
        pending.remove(userId)
        Log.info("✅ SESSION_CONFIRM[confirmed]: \(userId.prefix(8))… — RESPONDER acknowledged", category: "SessionConfirm")
    }

    // MARK: - Query (called by ChatViewModel)

    /// Returns true when the INITIATOR session for this peer is awaiting session_ready.
    /// ChatViewModel uses this to buffer outgoing messages as `.queued` instead of sending.
    func isPending(_ userId: String) -> Bool {
        pending.contains(userId)
    }
}
