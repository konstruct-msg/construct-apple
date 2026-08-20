//
//  LogSessionPreservationTests.swift
//  Construct MessengerTests
//
//  Keeping the previous session's log, without spending the window on empty ones.
//

import XCTest
@testable import Construct_Messenger

final class LogSessionPreservationTests: XCTestCase {

    /// A session that recorded something is what a bug report needs — usually more than the
    /// session doing the reporting, because a force-quit or a crash ends the interesting one.
    func testAnExistingSessionIsPreserved() {
        XCTAssertTrue(LogCollector.shouldPreserveSession(existingSize: 1))
        XCTAssertTrue(LogCollector.shouldPreserveSession(existingSize: 512_000))
    }

    /// Only three files are kept. Rotating empty ones would push real sessions out of the
    /// window: three launches that log nothing would leave nothing behind them.
    func testNothingRecordedIsNotWorthASlot() {
        XCTAssertFalse(LogCollector.shouldPreserveSession(existingSize: 0))
        XCTAssertFalse(LogCollector.shouldPreserveSession(existingSize: nil))
    }
}
