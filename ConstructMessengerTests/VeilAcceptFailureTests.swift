//
//  VeilAcceptFailureTests.swift
//  ConstructMessengerTests
//
//  The native veil-front listener ended on any failed `accept`, so one connection reset before it
//  was accepted left gRPC pointed at a port nobody accepted on (TODO 164, 2026-10-18).
//

import Darwin
import XCTest
@testable import Construct_Messenger

final class VeilAcceptFailureTests: XCTestCase {

    /// Mutation: end the loop on every failure (the old behaviour) — the retry cases redden.
    func testAConnectionFailingDoesNotEndTheListener() {
        XCTAssertEqual(VeilFrontExternalDialer.afterAcceptFailure(errno: ECONNABORTED, listenerCurrent: true), .retry)
        XCTAssertEqual(VeilFrontExternalDialer.afterAcceptFailure(errno: EINTR, listenerCurrent: true), .retry)
        XCTAssertEqual(VeilFrontExternalDialer.afterAcceptFailure(errno: EMFILE, listenerCurrent: true), .retryAfterPause)
    }

    /// Mutation: drop the `listenerCurrent` guard — the stopped case reddens.
    func testAStoppedOrBrokenListenerEnds() {
        XCTAssertEqual(VeilFrontExternalDialer.afterAcceptFailure(errno: ECONNABORTED, listenerCurrent: false), .stop)
        XCTAssertEqual(VeilFrontExternalDialer.afterAcceptFailure(errno: EBADF, listenerCurrent: true), .stop)
        XCTAssertEqual(VeilFrontExternalDialer.afterAcceptFailure(errno: EINVAL, listenerCurrent: true), .stop)
    }
}
