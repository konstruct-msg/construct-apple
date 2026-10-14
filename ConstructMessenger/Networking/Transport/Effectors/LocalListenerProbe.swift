//
//  LocalListenerProbe.swift
//  Construct Messenger
//
//  Whether a loopback port is still held — asked without connecting to it.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Asks the kernel, not the proxy, whether the local VEIL listener is there.
///
/// `veil_is_alive` answers whether the Rust coordinator holds a session. A suspended process keeps
/// that session after iOS has reclaimed its listening socket, and on the native-TLS path the
/// listener is not the coordinator's at all, so the answer is "no" while the port works. On
/// 2026-10-02 an incoming call woke the app: `is_alive` said yes, the push-wake restart was
/// skipped, and every RPC — the offer fetch included — was refused on 127.0.0.1.
///
/// The probe binds the port rather than connecting to it. A connect is not free here: every
/// connection the proxy accepts opens a tunnel to the front (TLS and AUTH), and on the native path
/// the first one takes the connection prepared at start. `bind` creates nothing:
///
/// - `EADDRINUSE` — something holds the port: alive.
/// - bind succeeds — nothing does: the listener is gone.
///
/// No `SO_REUSEADDR`, so every way this can be wrong (a lingering TIME_WAIT, a listener on the
/// wildcard address) reads as alive — which is what the caller did before it asked at all.
enum LocalListenerProbe {
    static func isHeld(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // EADDRINUSE is the answer; any other failure is not evidence the listener is gone.
        return result != 0
    }
}
