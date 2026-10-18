//
//  SendFailureTests.swift
//  ConstructMessengerTests
//
//  A send that got no answer keeps its message queued and its ciphertext (TODO 165, 2026-10-17:
//  `clientIsStopped` marked a message failed, its ciphertext was dropped, and three retries had
//  nothing to send).
//

import GRPCCore
import XCTest
@testable import Construct_Messenger

final class SendFailureTests: XCTestCase {

    /// The client was stopped under the call — a route change replaced the channel mid-send.
    /// Mutation: drop the `RuntimeError` branch — this reddens.
    func testAStoppedClientIsThePathNotTheMessage() {
        XCTAssertTrue(SendFailure.isRetryableTransport(RuntimeError(code: .clientIsStopped, message: "stopped")))
        XCTAssertTrue(SendFailure.isRetryableTransport(RuntimeError(code: .transportError, message: "transport")))
    }

    /// Mutation: drop the `GRPCClientError` line.
    func testOurOwnDeadlineIsThePath() {
        XCTAssertTrue(SendFailure.isRetryableTransport(GRPCClientError.clientSideTimeout))
    }

    func testTheKnownTransportCasesStayRetryable() {
        XCTAssertTrue(SendFailure.isRetryableTransport(VeilTunnelNotUp()))
        XCTAssertTrue(SendFailure.isRetryableTransport(RPCError(code: .unavailable, message: "")))
        XCTAssertTrue(SendFailure.isRetryableTransport(RPCError(code: .deadlineExceeded, message: "")))
        XCTAssertTrue(SendFailure.isRetryableTransport(NetworkError.notConnected))
    }

    /// A server's answer is not a path failure. Mutation: return true for any error.
    func testAnAnswerIsNotATransportFailure() {
        XCTAssertFalse(SendFailure.isRetryableTransport(RPCError(code: .permissionDenied, message: "")))
        XCTAssertFalse(SendFailure.isRetryableTransport(RPCError(code: .invalidArgument, message: "")))
        XCTAssertFalse(SendFailure.isRetryableTransport(RuntimeError(code: .serverIsStopped, message: "")))
    }
}
