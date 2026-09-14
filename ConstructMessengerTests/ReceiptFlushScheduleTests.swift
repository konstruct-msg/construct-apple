//
//  ReceiptFlushScheduleTests.swift
//  Construct MessengerTests
//
//  The property being bought is not "receipts are late". It is "when a receipt leaves says nothing
//  about when the message arrived, no matter how many times you watch".
//

import XCTest
@testable import Construct_Messenger

final class ReceiptFlushScheduleTests: XCTestCase {

    private let grid = ReceiptFlushSchedule(period: 20, phase: 7)

    // MARK: - The property

    /// The whole point. Two messages landing at different moments of the same cell leave at the
    /// same instant, so the send time cannot be differenced back to the arrival time.
    func testArrivalsInsideOneCellLeaveAtTheSameInstant() {
        let early = grid.nextFlush(after: 7.001)
        let late = grid.nextFlush(after: 26.999)

        XCTAssertEqual(early, late, accuracy: 0.0001, "one cell, one send")
        XCTAssertEqual(early, 27, accuracy: 0.0001, "phase 7 + one period")
    }

    /// And the reason a grid was chosen over `arrival + random`: repetition must not accumulate.
    /// The same conversational rhythm replayed at a hundred different offsets still produces send
    /// instants drawn from the grid alone, so averaging over exchanges reveals the grid, not the
    /// arrivals.
    func testRepeatedArrivalsNeverRevealTheirOffsetInTheCell() {
        let sends = Set((0..<100).map { i -> TimeInterval in
            let arrival = 7 + Double(i) * 0.13   // walks across one cell
            return (grid.nextFlush(after: arrival) * 1000).rounded() / 1000
        })

        XCTAssertEqual(sends, [27], "every arrival in the cell maps onto the one instant")
    }

    /// A receipt that arrives exactly on a tick waits a full period rather than going out at once.
    /// Otherwise "landed on the boundary" would be a visibly faster path than any other arrival.
    func testAnArrivalOnTheBoundaryWaitsAWholePeriod() {
        XCTAssertEqual(grid.delay(enqueuedAt: 7), 20, accuracy: 0.0001)
        XCTAssertEqual(grid.delay(enqueuedAt: 27), 20, accuracy: 0.0001)
    }

    // MARK: - Bounds

    /// Nothing waits longer than a period, and nothing goes out instantly.
    func testDelayStaysInsideOnePeriod() {
        for i in 0..<500 {
            let now = Double(i) * 0.37
            let delay = grid.delay(enqueuedAt: now)
            XCTAssertGreaterThan(delay, 0, "an instant send would be a timing channel")
            XCTAssertLessThanOrEqual(delay, 20.0001, "a receipt may not be held past one cell")
        }
    }

    /// Negative clocks are not exotic: `timeIntervalSinceReferenceDate` is negative before 2001 and
    /// a device with a wrong date produces one. The floor division must not fall over there.
    func testTheGridSurvivesTimesBeforeTheReferenceEpoch() {
        let delay = grid.delay(enqueuedAt: -13.5)

        XCTAssertGreaterThan(delay, 0)
        XCTAssertLessThanOrEqual(delay, 20.0001)
        XCTAssertEqual(grid.nextFlush(after: -13.5), -13, accuracy: 0.0001, "grid holds: … -33, -13, 7 …")
    }

    // MARK: - Phase

    /// The phase has to be ours, not the wall clock's — a grid everyone shares is a grid the
    /// observer already knows, and receipts across all users would line up on it.
    func testRandomPhasesLandInsideThePeriodAndDiffer() {
        let phases = (0..<64).map { _ in ReceiptFlushSchedule.random().phase }

        XCTAssertTrue(phases.allSatisfy { $0 >= 0 && $0 < ReceiptFlushSchedule.veilPeriod })
        XCTAssertGreaterThan(Set(phases).count, 1, "a constant phase would be no phase at all")
    }

    /// The direct path is not quantised: off VEIL the batcher is only collapsing redelivery storms
    /// and a checkmark should not be held for tens of seconds.
    func testTheDirectPathKeepsItsShortWindow() {
        XCTAssertEqual(ReceiptFlushSchedule.directDelay, 0.5)
        XCTAssertEqual(ReceiptFlushSchedule.veilPeriod, 20)
    }
}
