//
//  KeepaliveTimingTests.swift
//  ConstructMessengerTests
//
//  The direct-path ping was 10.0 s exactly — a rhythm one rule reads (TODO 162 B, 2026-10-18).
//

import XCTest
@testable import Construct_Messenger

final class KeepaliveTimingTests: XCTestCase {

    /// Mutation: set the jitter to 0 — this reddens.
    func testThePingHasNoFixedPeriod() {
        XCTAssertGreaterThan(NetworkTiming.GRPC.keepaliveJitter, 0)
        XCTAssertLessThan(NetworkTiming.GRPC.keepaliveJitter, 1)
    }

    /// The longest interval plus the ack wait stays inside the ~30 s a carrier NAT keeps an idle
    /// TCP flow. Mutation: raise the base to 25 s — this reddens.
    func testTheLongestDirectIntervalStaysInsideTheNatWindow() {
        let longest = Double(NetworkTiming.GRPC.keepaliveTimeDirectSeconds) * (1 + NetworkTiming.GRPC.keepaliveJitter)
        XCTAssertLessThan(longest + Double(NetworkTiming.GRPC.keepaliveTimeoutSeconds), 30)
    }
}
