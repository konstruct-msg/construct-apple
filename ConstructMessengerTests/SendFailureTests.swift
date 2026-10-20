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

    /// A thrown send leaves the message queued exactly when the path failed. Mutation: answer
    /// `.failed` for a stopped client — the first assertion reddens.
    func testAThrownSendIsQueuedOnlyWhenThePathFailed() {
        XCTAssertEqual(SendFailure.status(after: RuntimeError(code: .clientIsStopped, message: "")), .queued)
        XCTAssertEqual(SendFailure.status(after: VeilTunnelNotUp()), .queued)
        XCTAssertEqual(SendFailure.status(after: RPCError(code: .permissionDenied, message: "")), .failed)
    }

    /// One rule on the message path. The retry kept its own copy until 2026-10-20 and failed what
    /// the first send queued (TODO 175). Mutation: put a hand-written transport check back into
    /// `MessageRetryManager` — this reddens.
    func testNoMessagingFileClassifiesTransportErrorsItself() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Messaging")
        var copies: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name.hasSuffix(".swift") && name != "ChatSendCoordinator.swift" {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains(".deadlineExceeded") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                copies.append("\(name):\(n + 1)")
            }
        }
        XCTAssertEqual(copies, [], "classify through SendFailure.isRetryableTransport")
    }

    /// A server's answer is not a path failure. Mutation: return true for any error.
    func testAnAnswerIsNotATransportFailure() {
        XCTAssertFalse(SendFailure.isRetryableTransport(RPCError(code: .permissionDenied, message: "")))
        XCTAssertFalse(SendFailure.isRetryableTransport(RPCError(code: .invalidArgument, message: "")))
        XCTAssertFalse(SendFailure.isRetryableTransport(RuntimeError(code: .serverIsStopped, message: "")))
    }
}
