//
//  LocalListenerProbe.swift
//  Construct Messenger
//
//  Whether something accepts TCP connections on a loopback port.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Asks the socket, not the proxy, whether the local VEIL listener is there.
///
/// `veil_is_alive` answers whether the coordinator holds a session, and a suspended process keeps
/// that session after iOS has reclaimed its listening socket. On 2026-10-02 an incoming call woke
/// the app from the background: `is_alive` said yes, the push-wake restart was skipped, and every
/// RPC — the offer fetch included — was refused on 127.0.0.1. The call rang and never connected.
enum LocalListenerProbe {
    /// Loopback answers a connect at once — accepted or refused — so the wait only bounds a
    /// stalled backlog.
    static let timeoutMs: Int32 = 300

    static func accepts(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) == 1 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }
}
