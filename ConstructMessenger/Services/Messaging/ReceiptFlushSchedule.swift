//
//  ReceiptFlushSchedule.swift
//  Construct Messenger
//
//  When a batch of receipts leaves — decided by a clock, not by when the message arrived.
//
//  A delivery receipt is the cleanest correlation signal this client emits. A human reply lands
//  seconds to minutes after the message that prompted it, and that spread is what makes pairing two
//  subscribers expensive. A receipt is a device reflex: message in, receipt out one RTT plus a few
//  tens of milliseconds later, with a consistency no person has. An observer watching both ends
//  does not need twenty exchanges to pair them, and does not need to break anything — the reflex
//  latency is the tell. See construct-docs `decisions/veil-external-transport-review-2026-09` §2.1.
//
//  The fix is not to delay the send. `send = arrival + delay` still points at the arrival, and with
//  an independent random delay per batch the observer averages over repeated exchanges and recovers
//  it. The fix is to quantise: receipts leave only on the instants of a fixed grid whose phase is
//  drawn once per launch. Arrival then decides *which* cell a receipt belongs to and nothing more —
//  every arrival inside one cell produces the exact same send instant, so repetition adds no
//  information, and receipts owed to different contacts merge into the same instant for free.
//
//  The residual leak is the cell width: a receipt on the wire says the message arrived somewhere in
//  the preceding period. That is the floor for a transport without cadence, and it is the same
//  order as a human reply — which is the point.
//
//  Off the VEIL path none of this applies and the short batching window stays: there the batcher's
//  job is collapsing a redelivery storm, and a checkmark should not be held for tens of seconds.
//

import Foundation

/// The instants at which receipts are allowed to leave.
///
/// Pure and clock-free: callers pass the current time, so a test can argue with the arithmetic
/// rather than with a timer.
struct ReceiptFlushSchedule: Equatable {

    /// Spacing of the grid. Every receipt waits for the next multiple.
    let period: TimeInterval

    /// Offset of the grid from the reference epoch, in `[0, period)`.
    ///
    /// Drawn once per launch (`.random()`), never derived from anything an observer can see. Its
    /// only job is to stop the grid from being the wall clock, which everyone shares.
    let phase: TimeInterval

    /// The VEIL-path schedule: a 20-second grid, so a receipt waits 10 seconds on average and 20 at
    /// worst. Within the 10–30 s band the review argued for, at the end that costs the user less.
    static let veilPeriod: TimeInterval = 20

    /// The direct-path window. Long enough that a redelivery storm — tens of messages a second —
    /// collapses into single-digit sends, short enough that nobody sees a checkmark arrive late.
    static let directDelay: TimeInterval = 0.5

    /// A fresh grid with a random phase. Call once per process.
    static func random(period: TimeInterval = veilPeriod) -> ReceiptFlushSchedule {
        ReceiptFlushSchedule(period: period, phase: .random(in: 0..<period))
    }

    /// How long something enqueued at `now` waits before it may be sent.
    ///
    /// Always positive: an enqueue that lands exactly on a grid instant waits a full period rather
    /// than going out immediately, because "arrived precisely at a tick" must not be a faster path
    /// than any other arrival.
    func delay(enqueuedAt now: TimeInterval) -> TimeInterval {
        let elapsed = now - phase
        let intoCell = elapsed - (period * (elapsed / period).rounded(.down))
        let remaining = period - intoCell
        return remaining <= 0 ? period : remaining
    }

    /// The instant an enqueue at `now` is sent. Equal for every `now` inside one cell — that
    /// equality is the whole property, so it is what the tests assert on.
    func nextFlush(after now: TimeInterval) -> TimeInterval {
        now + delay(enqueuedAt: now)
    }
}
