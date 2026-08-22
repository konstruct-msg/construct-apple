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

    // MARK: - What a session archive does to that evidence

    /// What must happen to an outgoing message when the session it was encrypted under is archived.
    enum ArchiveOutcome: Equatable {
        /// Send it again. The retry path re-sends the stored ciphertext when it still has it, and
        /// otherwise re-encrypts the recoverable plaintext under the new session with a fresh id.
        case resend
        /// Attempts exhausted. Mark it failed so it stops re-queuing — and so the user can see that
        /// it did not arrive, instead of reading a checkmark that means nothing.
        case giveUp
        /// The peer confirmed it. No session change unsays that.
        case keep
    }

    /// `.sent` means the server took the ciphertext. That was evidence of *arrival* only for as
    /// long as the peer could decrypt it — and archiving the session ends exactly that. From the
    /// archive on, a `.sent` message the peer never confirmed is in the same position as one that
    /// never left this device.
    ///
    /// Until 2026-08-17 the archive path read it the other way round: a message whose stored wire
    /// payload had been dropped was skipped as "already accepted by server". The payload is dropped
    /// the moment the status becomes `.sent`, so that skipped every ordinary message — each one
    /// left at `.sent` forever, with a ciphertext on the server that the peer had just lost the
    /// keys for. On 2026-08-17, devices `7574fdec…`/`ffeeddc6…`: four messages, "already accepted
    /// by server", never seen by the recipient.
    ///
    /// The skip's own reasoning was sound when it was written on 2026-04-26 — re-queuing a message
    /// with no payload did fail instantly as `payload_expired`. The re-encrypt fallback that made
    /// it false landed on 2026-06-29 (`4519018c`), and nothing came back to this decision.
    static func afterSessionArchive(
        status: DeliveryStatus,
        retryCount: Int,
        maxRetries: Int
    ) -> ArchiveOutcome {
        if evidenceRank(status) >= evidenceRank(.delivered) { return .keep }
        return retryCount < maxRetries ? .resend : .giveUp
    }

    // MARK: - Which receipts may turn the checkmark on

    /// Where a delivery receipt came from. The two arrive at the same handler and are not the same
    /// fact.
    enum ReceiptSource: Equatable {
        /// The peer's own receipt: content_type 14, out of the Double Ratchet. Nobody but the peer
        /// could have produced it.
        case peerE2E
        /// A plaintext `DirectReceipt` relayed on the message stream. The server hands it to us and
        /// nothing in it is authenticated.
        case relayedStream
    }

    /// Whether a receipt from `source` may mark a message `.delivered`.
    ///
    /// `.delivered` is the one thing the UI says about the *other person*: your message reached
    /// them. `evidenceRank` already puts it above everything else and lets nothing demote it, which
    /// is right — and is exactly why what may produce it has to be narrow.
    ///
    /// A relayed stream receipt may not. gRPC/TLS ends at the server, so a plaintext receipt on that
    /// stream is a value the server chose to send: anything able to write there can turn on a
    /// checkmark claiming end-to-end delivery, for a message that was never delivered. This client
    /// has not *sent* one since 2026-08-02, so no current peer produces them either.
    ///
    /// **This reverses part of that 2026-08-02 decision, and the argument it was made on was
    /// sound as far as it went.** The inbound branch was kept because "reading a receipt leaks
    /// nothing" — true, and about privacy. The property it did not weigh is authenticity: the leak
    /// was the reason to stop sending, and it is not the only reason to stop believing. A peer on an
    /// older build loses its checkmarks, which alpha force-updates settle, and the same trade was
    /// taken for the v1/v2 call-signal formats.
    ///
    /// The relayed branch is still parsed and still refused *out loud* rather than deleted: the
    /// stream entry has a cursor that must advance, and one still arriving means either a peer older
    /// than three weeks or something that is not a peer at all. Both are worth seeing.
    static func marksDelivered(_ source: ReceiptSource) -> Bool {
        switch source {
        case .peerE2E:       return true
        case .relayedStream: return false
        }
    }
}
