//
//  VeilFerrySessionEndTests.swift
//  ConstructMessengerTests
//
//  When a native-TLS ferry session ends on its own (todo 315). After a suspend an RPC went into a
//  session that no longer reached the relay and waited out its 15 s timeout; the session ignored
//  its send errors and stopped watching the connection's state once the handshake was done.
//

import Network
import XCTest
@testable import Construct_Messenger

final class VeilFerrySessionEndTests: XCTestCase {

    /// Mutation: end on nothing (`return nil`) — the failed connection keeps its session, and the
    /// gRPC connection behind it waits out its timeout.
    func testAConnectionThatFailedAfterTheHandshakeEndsTheSession() {
        XCTAssertEqual(FerrySessionEnd.ending(.failed(.posix(.ECONNRESET))), .relayFailed)
    }

    /// Mutation: end on `.waiting` too — a path that comes back would find its session gone, and
    /// each blip would cost a new relay connection (and token).
    func testWaitingReadyAndOurOwnCancelDoNotEndIt() {
        XCTAssertNil(FerrySessionEnd.ending(.waiting(.posix(.ENETDOWN))))
        XCTAssertNil(FerrySessionEnd.ending(.ready))
        XCTAssertNil(FerrySessionEnd.ending(.cancelled))
        XCTAssertNil(FerrySessionEnd.ending(.preparing))
    }

    /// Mutations: ignore the send error again; end on a send that succeeded.
    func testAFailedSendEndsTheSessionAndASuccessfulOneDoesNot() {
        XCTAssertEqual(FerrySessionEnd.ending(sendError: .posix(.EPIPE)), .sendFailed)
        XCTAssertNil(FerrySessionEnd.ending(sendError: nil))
    }
}
