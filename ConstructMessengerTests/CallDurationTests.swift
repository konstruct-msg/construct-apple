//
//  CallDurationTests.swift
//  ConstructMessengerTests
//
//  The time on the call screen runs from the answer, not from the screen. Until 2026-11-09 the
//  screen counted its own ticks from 0 each time it appeared, so leaving it and coming back
//  started the call over (todo 287).
//

import XCTest
@testable import Construct_Messenger

final class CallDurationTests: XCTestCase {

    private let answer = Date(timeIntervalSince1970: 1_800_000_000)

    /// A screen that appears 90 s into the call shows 01:30 at once, with no tick counted.
    /// Mutation that reddens it: count from anything but `answeredAt` (e.g. a seconds value of 0).
    func testAScreenThatComesBackShowsTheCallsTime() {
        XCTAssertEqual(CallDuration.text(answeredAt: answer, now: answer.addingTimeInterval(90)), "01:30")
        XCTAssertEqual(CallDuration.text(answeredAt: answer, now: answer.addingTimeInterval(3_725)), "62:05")
    }

    /// Mutation that reddens it: return anything but 00:00 before an answer is known.
    func testNoAnswerYetReadsZero() {
        XCTAssertEqual(CallDuration.text(answeredAt: nil, now: answer), "00:00")
    }

    /// A clock that moved back reads 00:00, never a negative time.
    /// Mutation that reddens it: drop the `max(0, …)`.
    func testAClockThatMovedBackReadsZero() {
        XCTAssertEqual(CallDuration.text(answeredAt: answer, now: answer.addingTimeInterval(-5)), "00:00")
    }
}
