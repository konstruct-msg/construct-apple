//
//  DeliveryReceiptBatcher.swift
//  Construct Messenger
//
//  One receipt for many messages, instead of one receipt per message.
//
//  `ReceiptResendThrottle` closed the case it was written for: the *same* message redelivered over
//  and over answered once per window rather than once per delivery. It has no opinion about many
//  *different* messages arriving at once, because per-message that is the correct answer — each id
//  is legitimately owed exactly one receipt, and each one passes the throttle first and only time.
//
//  On 2026-08-19 the server replayed 4211 distinct messages in 65 seconds (`since_cursor` still
//  not honoured — decisions/diagnose-redelivery-before-fixing-it). 549 of them had a live session,
//  so 549 receipts went out in 15 seconds: 549 encrypts, 549 ratchet advances, 549 RPCs and 549
//  keychain writes of ~2 KB each, for information that fits in one message.
//
//  The proto has always taken a list — `DirectReceipt.messageIds` is repeated — and nothing was
//  filling it with more than one id. So this is not a new capability, it is the existing one being
//  used: hold ids for a beat, then send what accumulated as a single receipt.
//
//  A receipt moves a checkmark. Delaying it by well under a second is not observable; sending 549
//  of them is.
//

import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - The decision

/// What is owed to whom, and how it splits into receipts. Pure: no clock, no network, no Core
/// Data — the timing lives in `DeliveryReceiptBatcher`, and this is the part a test can argue with.
struct ReceiptBatchBuffer: Equatable {

    /// Ids owed per contact, in arrival order. Order is not required by the protocol; it is here so
    /// the split is deterministic and a test asserts on a value rather than on a set comparison.
    private(set) var pending: [String: [String]] = [:]
    private var seen: [String: Set<String>] = [:]

    var isEmpty: Bool { pending.isEmpty }

    /// Ceiling on one receipt's id list. A replay can queue thousands, and a single receipt
    /// carrying all of them is one oversized ciphertext instead of one storm — the padding budget
    /// and the sealed envelope both have limits. Draining in chunks keeps every send ordinary.
    static let maxIdsPerReceipt = 64

    /// Records that `messageId` is owed to `contactId`. Repeats inside the same buffer collapse:
    /// the throttle already decided this id is due once, and a second arrival before the flush is
    /// the storm, not a second obligation.
    mutating func add(messageId: String, to contactId: String) {
        if seen[contactId, default: []].contains(messageId) { return }
        seen[contactId, default: []].insert(messageId)
        pending[contactId, default: []].append(messageId)
    }

    /// Everything owed to one contact, leaving the rest buffered.
    ///
    /// Used when a real message is about to go out to that contact: the receipt rides next to a
    /// send the user just made, so its timing points at the user's own action rather than at when
    /// the peer's message landed. Everyone else keeps waiting for the grid — draining them here
    /// would attach *their* receipts to an action taken in a different conversation.
    mutating func drain(for contactId: String) -> [(contactId: String, messageIds: [String])] {
        guard let ids = pending.removeValue(forKey: contactId) else { return [] }
        seen.removeValue(forKey: contactId)
        return stride(from: 0, to: ids.count, by: Self.maxIdsPerReceipt).map { chunk in
            (contactId, Array(ids[chunk..<min(chunk + Self.maxIdsPerReceipt, ids.count)]))
        }
    }

    /// Everything owed, as the receipts that will carry it. The buffer is left empty.
    ///
    /// Contacts are drained in sorted order for the same reason ids keep arrival order: so the
    /// result is a value and not a coin flip.
    mutating func drain() -> [(contactId: String, messageIds: [String])] {
        var receipts: [(contactId: String, messageIds: [String])] = []
        for contactId in pending.keys.sorted() {
            guard let ids = pending[contactId] else { continue }
            for chunk in stride(from: 0, to: ids.count, by: Self.maxIdsPerReceipt) {
                receipts.append((contactId, Array(ids[chunk..<min(chunk + Self.maxIdsPerReceipt, ids.count)])))
            }
        }
        pending.removeAll()
        seen.removeAll()
        return receipts
    }
}

// MARK: - The timing

/// Collects due receipts for a short window and sends each contact's as one message.
@MainActor
final class DeliveryReceiptBatcher {

    static let shared = DeliveryReceiptBatcher()

    /// How long ids wait for company on the direct path.
    ///
    /// Long enough that a replay burst — which arrives as fast as the stream can decode, tens per
    /// second — collapses into single-digit sends. Short enough that a checkmark on a quiet
    /// one-message conversation is not something anyone notices arriving late.
    static let flushDelay: TimeInterval = ReceiptFlushSchedule.directDelay

    /// The grid receipts leave on while the traffic is going through VEIL. Phase is drawn once per
    /// process, so the instants are ours and not the wall clock's; see `ReceiptFlushSchedule` for
    /// why quantising beats delaying.
    private let schedule = ReceiptFlushSchedule.random()

    /// Whether the send should be decoupled from arrival right now.
    ///
    /// Read at scheduling time, not at enqueue: a batch started on the direct path and flushed
    /// after an escalation is a batch that went out early, which is harmless. The reverse — a
    /// receipt held for 20 seconds on a path where nobody is watching — is only a worse checkmark.
    private var isCensoredPath: Bool { TransportRouterMirror.shared.isUsingVEIL }

    private var buffer = ReceiptBatchBuffer()
    /// The recipient's identity key, resolved on the caller's Core Data queue at enqueue time and
    /// held until the flush. Resolving it later would mean touching Core Data from the flush, which
    /// is exactly the queue confinement `sendDeliveryReceipt` exists to respect.
    private var identityKeys: [String: Data] = [:]
    private var flushTask: Task<Void, Never>?
    private var lifecycleObserver: (any NSObjectProtocol)?

    private init() {
        #if os(iOS)
        // A pending batch is a receipt the peer is waiting for, and the throttle has already
        // recorded these ids as sent — so dropping the buffer on suspend loses them for the full
        // 10-minute window. Flush instead.
        //
        // This one send is deliberately not on the grid: backgrounding is a user action, so the
        // frame is coupled to it. The leak is bounded (it says a message arrived since the last
        // tick) and the observer already sees the tunnel go down a moment later. Losing the
        // receipt outright is the worse trade.
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { DeliveryReceiptBatcher.shared.flushNow() }
        }
        #endif
    }

    #if DEBUG
    /// Test seam: how many ids are waiting to be sent.
    ///
    /// `sendDeliveryReceipt`'s own-account suppression is otherwise unobservable — the whole
    /// difference between "dropped" and "enqueued" is inside this buffer, and a test that cannot
    /// see it can only assert the source text.
    var pendingCountForTesting: Int { buffer.pending.values.reduce(0) { $0 + $1.count } }

    /// Test seam: drop whatever is buffered without sending it.
    func discardForTesting() {
        flushTask?.cancel()
        flushTask = nil
        _ = drain()
    }
    #endif

    /// `messageId` is due to `contactId`. Callers have already asked `ReceiptResendThrottle`.
    func enqueue(messageId: String, to contactId: String, recipientIdentityKey: Data?) {
        buffer.add(messageId: messageId, to: contactId)
        if let recipientIdentityKey { identityKeys[contactId] = recipientIdentityKey }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = isCensoredPath
            ? schedule.delay(enqueuedAt: Date().timeIntervalSinceReferenceDate)
            : Self.flushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.send(self?.drain() ?? [])
        }
    }

    /// A real message is about to go out to `contactId` — send what is owed to them with it.
    ///
    /// Called from `OutboundMessagePipeline`. In a live conversation this is what actually delivers
    /// the checkmark, and it costs nothing: the outgoing frame the observer is about to see is the
    /// user's own send, so the receipt beside it says nothing the send did not already say. The
    /// grid timer keeps running for whatever is owed to everyone else.
    func flushPiggyback(to contactId: String) {
        let receipts = buffer.drain(for: contactId)
        guard !receipts.isEmpty else { return }
        let key = identityKeys.removeValue(forKey: contactId)
        if buffer.isEmpty {
            flushTask?.cancel()
            flushTask = nil
        }
        send(receipts.map { ($0.contactId, $0.messageIds, key) })
    }

    /// Sends whatever is buffered right now, without waiting out the window.
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        send(drain())
    }

    private func drain() -> [(contactId: String, messageIds: [String], identityKey: Data?)] {
        let receipts = buffer.drain()
        let keys = identityKeys
        identityKeys.removeAll()
        return receipts.map { ($0.contactId, $0.messageIds, keys[$0.contactId]) }
    }

    private func send(_ receipts: [(contactId: String, messageIds: [String], identityKey: Data?)]) {
        for receipt in receipts {
            if receipt.messageIds.count > 1 {
                PerformanceMetrics.shared.record(
                    .receiptsBatched, label: "\(receipt.messageIds.count)"
                )
            }
            Task { @MainActor in
                await OutboundSessionService.shared.sendEncryptedDeliveryReceipt(
                    messageIds: receipt.messageIds,
                    to: receipt.contactId,
                    recipientIdentityKey: receipt.identityKey
                )
            }
        }
    }

    #if DEBUG
    func resetForTesting() {
        flushTask?.cancel()
        flushTask = nil
        buffer = ReceiptBatchBuffer()
        identityKeys.removeAll()
    }
    #endif
}
