//
//  QuicRecvPumpDispositionTests.swift
//  ConstructMessengerTests
//
//  The three QUIC errors in the 2026-09-23 France log are the recv pump noticing
//  a connection this process just shut down. A timeout is a different sentence
//  and stays an error.
//

import XCTest
@testable import Construct_Messenger

final class QuicRecvPumpDispositionTests: XCTestCase {

    func testGracefulShutdownCloseIsNotAnError() {
        let logged = "Transport(\"recv_data: Connection error: Remote error: Error undefined by h3: closed\")"
        XCTAssertEqual(QuicRecvPumpDisposition.classify(logged), .expectedClose)
    }

    func testTimeoutStaysAFailure() {
        let logged = "Transport(\"recv_response: Connection error: Timeout\")"
        XCTAssertEqual(QuicRecvPumpDisposition.classify(logged), .failure)
    }
}
