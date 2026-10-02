//
//  LocalListenerProbeTests.swift
//  ConstructMessengerTests
//
//  The push-wake restart asks whether the local VEIL listener accepts; the answer has to come from
//  the socket, because a session that outlived its port said yes (2026-10-02).
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

    func testAListeningPortAccepts() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        XCTAssertTrue(LocalListenerProbe.accepts(port: port))
    }

    /// What the suspended app had: the port it remembered, with nothing behind it.
    func testAClosedPortDoesNotAccept() throws {
        let (fd, port) = try listen()
        close(fd)
        XCTAssertFalse(LocalListenerProbe.accepts(port: port))
    }
}
