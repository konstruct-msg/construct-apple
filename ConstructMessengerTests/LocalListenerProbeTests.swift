//
//  LocalListenerProbeTests.swift
//  ConstructMessengerTests
//
//  The push-wake and foreground restart ask whether the local VEIL listener still holds its port.
//  The answer has to come from the kernel and must not cost a connection: every connection the
//  proxy accepts opens a tunnel to the front (2026-10-02).
//

import XCTest
import Darwin
@testable import Construct_Messenger

final class LocalListenerProbeTests: XCTestCase {
    /// A listening socket on an ephemeral loopback port; returns the fd and the port.
    private func listen() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    func testAListeningPortIsHeld() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        XCTAssertTrue(LocalListenerProbe.isHeld(port: port))
    }

    /// What the suspended app had: the port it remembered, with nothing behind it.
    func testAClosedPortIsNotHeld() throws {
        let (fd, port) = try listen()
        close(fd)
        XCTAssertFalse(LocalListenerProbe.isHeld(port: port))
    }

    /// The reason the probe binds rather than connects: asking must not hand the listener a
    /// connection, because the proxy turns every accepted connection into a tunnel.
    func testProbingLeavesNoConnectionToAccept() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        XCTAssertTrue(LocalListenerProbe.isHeld(port: port))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let accepted = accept(fd, nil, nil)
        let acceptErrno = errno
        if accepted >= 0 { close(accepted) }
        XCTAssertEqual(accepted, -1, "the probe must not have connected")
        XCTAssertEqual(acceptErrno, EWOULDBLOCK)
    }
}
