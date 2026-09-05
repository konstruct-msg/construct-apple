//
//  PendingSessionQueue.swift
//  Construct Messenger
//
//  Owns the "messages that arrived before their sender's session was ready" queue.
//  Previously this was `pendingFirstMessages: inout [String:[ChatMessage]]` threaded
//  through MessageRouter and SessionCoordinator as a shared mutable reference.
//

import Foundation

/// Thread-safe (MainActor) queue of incoming messages that arrived before the
/// corresponding DR session was established. Keyed by sender userId.
@MainActor
final class PendingSessionQueue {

    /// A queued message and when **we** received it.
    ///
    /// Our arrival time, not the message's own timestamp: the latter is the sender's clock, and a
    /// handshake replayed out of the server's backlog carries a timestamp from before whatever we
    /// are currently deciding. What callers ask of this is "is the peer opening a session *now*",
    /// and only local arrival answers that.
    private struct Held {
        let message: ChatMessage
        let receivedAt: Date
    }

    private var queues: [String: [Held]] = [:]
    private let maxPerUser = 100

    // MARK: - Write

    /// Enqueue `message` for `userId`. No-op when the queue is already at capacity.
    /// Returns `true` if the message was accepted, `false` if the cap was hit.
    @discardableResult
    // Keyed by **account**, and it cannot move to a device until §D of the multi-device plan
    // lands. Everything here is filed from an incoming envelope, and the relay blanks
    // `sender_device` by design — there is no device to key by at the moment a message is held.
    // Step 1 of `session-is-one-state-machine` lists this queue, and measuring it is what showed
    // §D is *inside* that step rather than after it.
    func enqueue(_ message: ChatMessage, for userId: String) -> Bool {
        let current = queues[userId]?.count ?? 0
        guard current < maxPerUser else { return false }
        queues[userId, default: []].append(Held(message: message, receivedAt: Date()))
        return true
    }

    /// Ensure a slot exists for `userId` without adding a message.
    /// Used to mark "we've started handling this contact" so later messages
    /// don't re-trigger first-message logic for the same contact.
    func touch(_ userId: String) {
        if queues[userId] == nil { queues[userId] = [] }
    }

    /// Remove all queued messages for `userId` without returning them.
    func remove(for userId: String) {
        queues.removeValue(forKey: userId)
    }

    // MARK: - Read

    /// Atomically drain and return all queued messages for `userId`.
    /// The queue for `userId` is cleared as a side-effect.
    func drain(for userId: String) -> [ChatMessage] {
        defer { queues.removeValue(forKey: userId) }
        return (queues[userId] ?? []).map(\.message)
    }

    func contains(messageId: String, for userId: String) -> Bool {
        queues[userId]?.contains { $0.message.id == messageId } ?? false
    }

    func count(for userId: String) -> Int {
        queues[userId]?.count ?? 0
    }

    /// Snapshot of queued messages, without draining. Used to pick a handshake carrier
    /// when the message that triggered the bundle fetch is a mid-session leftover.
    func messages(for userId: String) -> [ChatMessage] {
        (queues[userId] ?? []).map(\.message)
    }

    /// Queued messages that arrived within `window`, newest-first.
    ///
    /// For callers asking whether something is happening *right now* rather than what is being
    /// held. A queue entry has no upper age: it stays until a session opens or the queue is
    /// cleared, so "there is a handshake here" and "the peer is opening a session" are different
    /// statements, and reading the first as the second is what deadlocked 2026-09-04 18:08.
    func messages(for userId: String, arrivedWithin window: TimeInterval) -> [ChatMessage] {
        let cutoff = Date().addingTimeInterval(-window)
        return (queues[userId] ?? [])
            .filter { $0.receivedAt > cutoff }
            .sorted { $0.receivedAt > $1.receivedAt }
            .map(\.message)
    }

    var isEmpty: Bool { queues.isEmpty }
}
