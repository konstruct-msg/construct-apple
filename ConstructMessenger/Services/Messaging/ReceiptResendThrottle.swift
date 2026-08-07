//
//  ReceiptResendThrottle.swift
//  Construct Messenger
//
//  One receipt per message per window, instead of one per redelivery.
//
//  The rule it replaces was reasonable read alone: "the message is already in the transcript, the
//  sender is redelivering because our first receipt never landed, so re-sending it is the only
//  thing that will move their checkmark". True for *a* redelivery. Under a redelivery storm it
//  becomes an amplifier, and on 2026-08-04 it cooked a phone:
//
//    6236 "Skipping already-processed" → 3754 outgoing sends in a few minutes, each a fresh
//    encrypt + ratchet advance + RPC. The device ran hot and the UI stalled.
//
//  It is worse than a linear cost, because our receipts are themselves messages: they enter the
//  peer's stream, the server replays those too (see decisions/diagnose-redelivery-before-fixing-it
//  — `since_cursor` is not honoured), and the peer answers them. Two clients can hold each other
//  at full tilt with no user doing anything.
//
//  The window is deliberately long. A receipt exists to move a checkmark, not to stop redelivery
//  (that is cursor-driven and independent), so losing one is a cosmetic, rare event and answering
//  it again ten minutes later still resolves it inside any real conversation. A short window would
//  cut the observed 24-per-message to maybe 6 and leave the amplifier standing.
//

import Foundation

/// Remembers which message ids we have recently sent a delivery receipt for.
///
/// In-memory on purpose. After a relaunch one extra receipt per message is harmless; persisting
/// this would trade a real cost (disk, another store to keep honest) for nothing.
final class ReceiptResendThrottle {

    static let shared = ReceiptResendThrottle()

    /// Long enough that a redelivery storm cannot pump it, short enough that a genuinely lost
    /// receipt is re-sent while the conversation is still alive.
    static let window: TimeInterval = 10 * 60

    /// Hard cap so a storm cannot turn this into unbounded memory — the thing it exists to stop.
    /// On overflow the oldest entries go first; the worst case of evicting too early is one extra
    /// receipt, which is exactly what the throttle tolerates anyway.
    static let maxEntries = 4096

    private let queue = DispatchQueue(label: "construct.ReceiptResendThrottle")
    private var sentAt: [String: Date] = [:]

    private init() {}

    /// True when a receipt for `messageId` should go out now. Records the decision.
    func shouldSend(messageId: String, now: Date = Date()) -> Bool {
        queue.sync {
            if let last = sentAt[messageId], now.timeIntervalSince(last) < Self.window {
                return false
            }
            if sentAt.count >= Self.maxEntries { evictOldest(keeping: Self.maxEntries * 3 / 4) }
            sentAt[messageId] = now
            return true
        }
    }

    /// Whether a receipt for `messageId` is currently suppressed — **without recording anything**.
    ///
    /// `shouldSend` is a decision *and* a write, so it cannot be used to ask the question. The
    /// redelivery fast path needs to know whether anything is still owed for a message before it
    /// spends an unseal finding out; asking with `shouldSend` would consume the slot for a receipt
    /// it then never sends.
    func isThrottled(messageId: String, now: Date = Date()) -> Bool {
        queue.sync {
            guard let last = sentAt[messageId] else { return false }
            return now.timeIntervalSince(last) < Self.window
        }
    }

    /// Filter a batch, keeping only the ids that are due.
    func due(_ messageIds: [String], now: Date = Date()) -> [String] {
        messageIds.filter { shouldSend(messageId: $0, now: now) }
    }

    func resetForTesting() {
        queue.sync { sentAt.removeAll() }
    }

    private func evictOldest(keeping: Int) {
        guard sentAt.count > keeping else { return }
        let survivors = sentAt.sorted { $0.value > $1.value }.prefix(keeping)
        sentAt = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }
}
