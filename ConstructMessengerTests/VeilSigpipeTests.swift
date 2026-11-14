//
//  VeilSigpipeTests.swift
//  ConstructMessengerTests
//
//  A write to a socket whose peer has closed raised SIGPIPE and ended the app: a VEIL front
//  demoted while sends were in flight closed one side of a native-TLS session, and the other
//  side's next write killed the process (todo 313, 2026-11-13 and 2026-11-14). The Rust ferry's
//  half is reproduced in construct-veil tests/ferry_sigpipe.rs; these pin the app's half.
//

import Darwin
import XCTest
@testable import Construct_Messenger

final class VeilSigpipeTests: XCTestCase {

    private func noSigpipe(_ fd: Int32) -> Int32 {
        var value: Int32 = -1
        var len = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &len), 0)
        return value
    }

    /// Mutation: drop either `refusesSigpipe` in `makeSessionPair` — that end reads 0.
    func testBothEndsOfASessionPairRefuseSigpipe() throws {
        let pair = try XCTUnwrap(VeilFrontExternalDialer.makeSessionPair())
        defer { close(pair.swiftFD); close(pair.rustFD) }
        XCTAssertNotEqual(noSigpipe(pair.swiftFD), 0, "our end — the pump writes the relay's bytes into it")
        XCTAssertNotEqual(noSigpipe(pair.rustFD), 0, "Rust's end — the ferry writes gRPC's bytes into it")
        XCTAssertNotEqual(fcntl(pair.swiftFD, F_GETFL, 0) & O_NONBLOCK, 0, "our end stays non-blocking for DispatchIO")
    }

    /// The effect: once Rust's end is gone, a write on ours fails with EPIPE and the process
    /// lives. (If SIGPIPE were raised here, this test process would die, not fail.)
    func testAWriteAfterThePeerClosedFailsInsteadOfKillingTheApp() throws {
        let pair = try XCTUnwrap(VeilFrontExternalDialer.makeSessionPair())
        defer { close(pair.swiftFD) }
        close(pair.rustFD)
        let byte: [UInt8] = [0x42]
        let n = byte.withUnsafeBytes { write(pair.swiftFD, $0.baseAddress, 1) }
        XCTAssertEqual(n, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    /// Mutation: make `refusesSigpipe` a no-op returning true — the option reads 0.
    func testAnAcceptedSocketCanBeGuarded() {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertEqual(noSigpipe(fds[0]), 0, "a plain socket raises SIGPIPE — the default this guards")
        XCTAssertTrue(VeilFrontExternalDialer.refusesSigpipe(fds[0]))
        XCTAssertNotEqual(noSigpipe(fds[0]), 0)
    }
}
