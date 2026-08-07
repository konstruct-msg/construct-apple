//
//  ReceiptResendThrottleTests.swift
//  ConstructMessengerTests
//
//  A receipt per redelivery is an amplifier, not a retry.
//
//  Measured 2026-08-04: 6236 already-processed duplicates produced 3754 outgoing sends in minutes
//  — each a full encrypt, ratchet advance and RPC. The phone ran hot and the UI stalled. It
//  compounds rather than merely repeating, because a receipt is itself a message: it lands in the
//  peer's stream, the server replays it back (`since_cursor` is not honoured), and it is answered
//  again.
//
//  What must survive the fix: a genuinely lost receipt is still re-sent, because it is the only
//  thing that moves the sender's checkmark off "sent".
//

import XCTest
@testable import Construct_Messenger

final class ReceiptResendThrottleTests: XCTestCase {

    private let throttle = ReceiptResendThrottle.shared

    override func setUp() {
        super.setUp()
        throttle.resetForTesting()
    }

    /// The storm: the same id arriving over and over must cost exactly one send.
    func testOneSendPerMessageInsideTheWindow() {
        let id = UUID().uuidString
        XCTAssertTrue(throttle.shouldSend(messageId: id), "the first redelivery still answers")
        for _ in 0..<500 {
            XCTAssertFalse(throttle.shouldSend(messageId: id),
                           "every further duplicate must be free — this is the amplifier")
        }
    }

    /// The recovery this exists to preserve: after the window, a lost receipt is re-sent.
    func testSendsAgainAfterTheWindow() {
        let id = UUID().uuidString
        let t0 = Date()
        XCTAssertTrue(throttle.shouldSend(messageId: id, now: t0))
        XCTAssertFalse(throttle.shouldSend(messageId: id, now: t0.addingTimeInterval(ReceiptResendThrottle.window - 1)))
        XCTAssertTrue(throttle.shouldSend(messageId: id, now: t0.addingTimeInterval(ReceiptResendThrottle.window + 1)),
                      "a receipt that never landed must get another chance while the chat is alive")
    }

    /// Throttling is per message, never global — one noisy id must not silence a different one.
    func testDistinctMessagesAreIndependent() {
        let a = UUID().uuidString, b = UUID().uuidString
        XCTAssertTrue(throttle.shouldSend(messageId: a))
        XCTAssertTrue(throttle.shouldSend(messageId: b),
                      "a second message deserves its own receipt immediately")
    }

    /// A batch keeps only the ids that are due, and keeps their order.
    func testBatchFilterKeepsOnlyDueIds() {
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString
        _ = throttle.shouldSend(messageId: b)
        XCTAssertEqual(throttle.due([a, b, c]), [a, c])
    }

    /// The cap must hold under exactly the storm it is there for — unbounded growth would recreate
    /// the problem in memory instead of on the radio.
    func testMemoryIsBoundedUnderAStorm() {
        for _ in 0..<(ReceiptResendThrottle.maxEntries * 2) {
            _ = throttle.shouldSend(messageId: UUID().uuidString)
        }
        // Eviction keeps the newest; the oldest ids may send once more, which the window tolerates.
        let recent = UUID().uuidString
        XCTAssertTrue(throttle.shouldSend(messageId: recent))
        XCTAssertFalse(throttle.shouldSend(messageId: recent),
                       "eviction must not have dropped what was just recorded")
    }

    // MARK: - Asking must not answer (the redelivery fast path needs a peek)

    /// `shouldSend` is a decision *and* a write. The fast path has to ask whether anything is
    /// still owed for a message *before* spending an unseal to find out, and asking with
    /// `shouldSend` would consume the slot for a receipt it then never sends.
    ///
    /// Mutation: implement `isThrottled` as `!shouldSend(...)` and this goes red.
    func testIsThrottledDoesNotConsumeTheSlot() {
        let throttle = ReceiptResendThrottle.shared
        throttle.resetForTesting()
        let id = "5f1c0b7e-0000-4abc-8def-0123456789ab"

        XCTAssertFalse(throttle.isThrottled(messageId: id), "nothing sent yet — nothing suppressed")
        XCTAssertFalse(throttle.isThrottled(messageId: id), "asking twice must still not record")
        XCTAssertTrue(throttle.shouldSend(messageId: id), "the first real send is still due")
        XCTAssertTrue(throttle.isThrottled(messageId: id), "and is suppressed afterwards")
    }

    /// The window is the same one `shouldSend` uses — a peek that disagreed with the decision
    /// would let the fast path skip a message that still owed a receipt.
    func testIsThrottledExpiresWithTheWindow() {
        let throttle = ReceiptResendThrottle.shared
        throttle.resetForTesting()
        let id = "aa11bb22-0000-4abc-8def-0123456789ab"
        let now = Date()

        XCTAssertTrue(throttle.shouldSend(messageId: id, now: now))
        XCTAssertTrue(throttle.isThrottled(messageId: id, now: now.addingTimeInterval(ReceiptResendThrottle.window - 1)))
        XCTAssertFalse(throttle.isThrottled(messageId: id, now: now.addingTimeInterval(ReceiptResendThrottle.window + 1)))
    }

    // MARK: - Dropping a redelivery before the unseal (build 584)

    //  Four minutes on one device: 12 252 incoming, 12 204 already processed, 12 170 sealed-sender
    //  signature verifications, CPU 100–128 % sustained, thermal nominal → fair. Every redelivery
    //  paid an Ed25519 verification before reaching the duplicate check that discarded it.

    /// The regression this exists to prevent returning: an ordinary redelivery with its receipt
    /// already suppressed has nothing left to do, and must not be unsealed to discover that.
    func testSettledRedeliveryIsSkippedBeforeUnseal() {
        XCTAssertTrue(
            MessageRouter.canSkipRedeliveryBeforeUnseal(
                isProcessed: true, messageNumber: 7, receiptStillThrottled: true
            )
        )
    }

    /// A first delivery is never skipped — that would drop real messages.
    func testFirstDeliveryIsNeverSkipped() {
        XCTAssertFalse(
            MessageRouter.canSkipRedeliveryBeforeUnseal(
                isProcessed: false, messageNumber: 7, receiptStillThrottled: true
            ),
            "skipping an unprocessed message loses it outright"
        )
    }

    /// msgNum 0 keeps the full path: the orphaned-init exception needs the unsealed content type
    /// and sender to decide, and re-processing a lost init is how a crashed handshake recovers.
    /// It was 1.1 % of the traffic, so keeping it costs nothing.
    func testSessionInitAlwaysTakesTheFullPath() {
        XCTAssertFalse(
            MessageRouter.canSkipRedeliveryBeforeUnseal(
                isProcessed: true, messageNumber: 0, receiptStillThrottled: true
            ),
            "an orphaned init must still be able to re-establish a session lost after its ACK"
        )
    }

    /// A duplicate that still owes a receipt takes the full path — the resend needs the sender,
    /// and the sender comes from the unseal.
    func testRedeliveryStillOwingAReceiptTakesTheFullPath() {
        XCTAssertFalse(
            MessageRouter.canSkipRedeliveryBeforeUnseal(
                isProcessed: true, messageNumber: 7, receiptStillThrottled: false
            ),
            "the receipt is the only thing that can move the sender's checkmark off 'sent'"
        )
    }

    /// All three conditions are load-bearing; none of them alone is enough.
    func testEveryConditionIsRequired() {
        let skippable = MessageRouter.canSkipRedeliveryBeforeUnseal(
            isProcessed: true, messageNumber: 7, receiptStillThrottled: true
        )
        XCTAssertTrue(skippable)
        for (processed, num, throttled) in [
            (false, UInt32(7), true), (true, UInt32(0), true), (true, UInt32(7), false)
        ] {
            XCTAssertFalse(
                MessageRouter.canSkipRedeliveryBeforeUnseal(
                    isProcessed: processed, messageNumber: num, receiptStillThrottled: throttled
                )
            )
        }
    }
}
