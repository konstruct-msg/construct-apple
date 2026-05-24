//
//  IceTransportRequest.swift
//  Construct Messenger
//
//  Fully describes a single proxy start attempt — transport type, addresses, and keys.
//  Passed to `IceProxyRuntime.start(_:)`. The runtime owns no selection policy; it only
//  executes the C FFI call that corresponds to the request variant.
//

import Foundation

/// Transport configuration for one proxy start attempt.
enum IceTransportRequest: Sendable {
    /// WebTunnel (ICE v2): HTTP CONNECT-style upgrade over TLS.
    /// The auth token is computed per-connection inside Rust from `bridgeCert`.
    case webTunnel(address: String, sni: String, spki: String, hostHeader: String, bridgeCert: String, wtBasePath: String)

    /// obfs4 tunnelled inside TLS with SPKI certificate pinning and a Chrome 131 TLS fingerprint.
    case tlsPinned(bridgeLine: String, address: String, sni: String, spki: String, profile: String)

    /// obfs4 tunnelled inside TLS with CA-chain certificate validation (no pinning).
    case tlsUnpinned(bridgeLine: String, address: String, sni: String)

    /// Plain obfs4 without a TLS wrapper.
    case plainObfs4(bridgeLine: String, address: String)
}

/// Runtime-level error from a proxy start attempt.
enum IceProxyRuntimeError: Error, Sendable {
    /// Rust returned code 2 — local network interface is unreachable.
    case networkUnreachable
    /// Any non-zero return code other than `networkUnreachable` (bad cert, bad address, etc.).
    case startFailed(code: Int32)

    var userFacingMessage: String {
        switch self {
        case .networkUnreachable: return "Failed to start proxy (network unreachable)"
        case .startFailed:        return "Failed to start proxy (check bridge cert)"
        }
    }
}
