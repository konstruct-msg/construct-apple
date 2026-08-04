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
}
