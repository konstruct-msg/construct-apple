//
//  DeliveryStatusTransition.swift
//  Construct Messenger
//
//  Who outranks whom when two writers disagree about a message's delivery status.
//

import Foundation

/// A message's delivery status is written from ~30 places: the send outcome, the peer's E2E
/// receipt, the server's stream receipt, the retry manager, the queue timeout, the session
/// re-init resend. They do not run in a defined order, and until this type existed the last
/// writer won regardless of what it actually knew.
///
/// Build 585, device 0a1c609f:
///
///     10:55:0x  Receipt: message 0224077a… marked delivered (was sending)
///     10:55:47  SendMessage gRPC error: code=unavailable, message=Stream unexpectedly closed.
///     10:55:47  Transport failure — queueing 0224077a… for safe retry
///     10:55:47  Updated message status to queued for 0224077a…
///
/// The peer had already confirmed the message. Forty seconds later the *request's* own reply
/// path died, and the error handler demoted a delivered message back into the retry queue —
/// where one of two things happens, both wrong: the plaintext is still recoverable and the
/// message is re-encrypted and sent a second time (the peer sees a duplicate), or it is not
/// and the row sticks at "queued" forever, unsendable and unshowable:
///
///     sendQueuedMessages: no queued messages with reusable wire payload or recoverable
///     plaintext for 0a1c609f… — preserving local queue        (×3, from an earlier session)
///
/// The rule that resolves it: **a transport failure is ignorance, not a negative result.**
/// `.sent` and `.delivered` are statements about where the message got to — the server said so,
/// the peer said so. `.sending`, `.queued` and `.failed` are statements about our own attempt
/// and carry no information about arrival. Ignorance must never overwrite evidence.
enum DeliveryStatusTransition {

    /// How much this status proves about the message having reached someone else.
    /// Statuses describing only our local attempt rank 0 — they are mutually interchangeable,
    /// which is what lets a queued message become sending, failed, or queued again.
    static func evidenceRank(_ status: DeliveryStatus) -> Int {
        switch status {
        case .delivered: return 2   // the peer's E2E receipt: it arrived, end to end
        case .sent:      return 1   // the server accepted it: it left this device
        case .sending, .queued, .failed: return 0   // about our attempt, not about arrival
        }
    }

    /// The status that must actually be stored, or `nil` when the write is refused.
    ///
    /// Refusal is not an error: it is the normal outcome of a slower writer arriving with a
    /// weaker fact. The caller keeps whatever it had.
    static func resolve(current: DeliveryStatus, proposed: DeliveryStatus) -> DeliveryStatus? {
        guard evidenceRank(proposed) >= evidenceRank(current) else { return nil }
        return proposed
    }
}
