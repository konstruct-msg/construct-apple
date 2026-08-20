//
//  TokenSpendUnit.swift
//  Construct Messenger
//
//  One Privacy Pass token per *logical* message, not per wire envelope.
//
//  A chunked body — an album, a long text, a voice descriptor — becomes many sealed sends, and
//  each one used to attach its own token. A three-photo album is ~30 wire envelopes, so it spent
//  30 tokens and emptied a young account's whole hourly allowance (30/hr) in one tap. The
//  anti-abuse budget was being charged per packet for something the user did once.
//
//  Server side (construct-server 2a64177) redeems per unit: the first envelope carrying a token
//  plus a `token_spend_id` redeems it and writes `pp:unit:{sha256(id)}` for 2h; later envelopes
//  with the same id are accepted as `unit_covered` without a new spend, up to 256 envelopes. An
//  empty spend id keeps the old per-envelope behaviour, so single-envelope sends are untouched.
//
//  This object is the client half: it holds the id and, more importantly, the answer to "has
//  anyone actually paid yet". That distinction is the whole reason this is a stateful object
//  rather than a `let spendId` threaded through a loop. Attaching a token can fail for reasons
//  that have nothing to do with the unit — an empty wallet, a server key not yet cached — and if
//  the *first* envelope is the only one that ever tries, one such failure leaves all thirty
//  envelopes uncovered. Under enforce that is a whole album rejected because of one unlucky
//  moment. So the role is claimed by whoever succeeds, not by whoever is first.
//

import Foundation

/// The economic unit of a send: one logical message, however many envelopes it takes.
///
/// Not `Sendable` on purpose — it is `@MainActor`, mutated only from the sealed-send path, which
/// is a sequential loop. If a future caller wants to fan chunks out concurrently, the payer race
/// has to be thought about rather than inherited.
@MainActor
final class TokenSpendUnit {

    /// Identical on every envelope of this message. 32 random bytes, per the proto contract.
    let spendId: Data

    /// True once an envelope has actually attached a token — not merely tried to.
    private(set) var isPaid = false

    init() {
        self.spendId = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }

    /// Test seam. Production always randomises.
    init(spendId: Data) {
        self.spendId = spendId
    }

    /// Should the envelope being built right now attempt to spend a token?
    ///
    /// Yes until one has succeeded. This is what makes a failed first attach recoverable instead
    /// of fatal to the whole unit.
    var shouldAttemptPayment: Bool { !isPaid }

    /// Called only when a token was really attached to an envelope.
    func markPaid() {
        isPaid = true
    }

    /// A unit for a message of `envelopeCount` wire envelopes, or nil when there is nothing to
    /// amortise. A single-envelope send leaves the spend id empty and takes the legacy
    /// per-envelope path — the only shape the server has redeemed until now, and the one that
    /// must not change.
    static func forEnvelopeCount(_ envelopeCount: Int) -> TokenSpendUnit? {
        envelopeCount > 1 ? TokenSpendUnit() : nil
    }

    /// Should the envelope being built attempt to spend a token?
    ///
    /// The decision `buildSealedInner` actually runs, lifted out of it: policy asks for a token,
    /// and the unit has not been paid for yet. `unitPaid` is false for a nil unit, which is what
    /// makes an un-chunked send behave exactly as before.
    nonisolated static func shouldAttemptPayment(policyWantsToken: Bool, unitPaid: Bool) -> Bool {
        policyWantsToken && !unitPaid
    }

    /// The server rejected the unit — its record of our spend is gone or was never written.
    ///
    /// Used by the one-shot enforce recovery in `StealthSendRecovery`: a `privacy_pass` rejection
    /// means the envelope we thought had paid did not, so the rebuilt envelope must pay again.
    /// Without this the rebuild would attach the same unpaid spend id and be rejected identically,
    /// turning a recoverable rejection into a permanent one.
    func invalidatePayment() {
        isPaid = false
    }
}
