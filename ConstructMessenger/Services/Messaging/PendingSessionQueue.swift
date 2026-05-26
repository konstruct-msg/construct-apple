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

    private var queues: [String: [ChatMessage]] = [:]
    private let maxPerUser = 100

    // MARK: - Write

    /// Enqueue `message` for `userId`. No-op when the queue is already at capacity.
    /// Returns `true` if the message was accepted, `false` if the cap was hit.
    @discardableResult
    func enqueue(_ message: ChatMessage, for userId: String) -> Bool {
        let current = queues[userId]?.count ?? 0
        guard current < maxPerUser else { return false }
        queues[userId, default: []].append(message)
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
        return queues[userId] ?? []
    }

    func contains(messageId: String, for userId: String) -> Bool {
        queues[userId]?.contains { $0.id == messageId } ?? false
    }

    func count(for userId: String) -> Int {
        queues[userId]?.count ?? 0
    }

    var isEmpty: Bool { queues.isEmpty }
}
