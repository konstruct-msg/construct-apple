//
//  VeilTransportRequest.swift
//  Construct Messenger
//
//  Fully describes a single proxy start attempt — transport type, addresses, and keys.
//  Passed to `VeilProxyRuntime.start(_:)`. The runtime owns no selection policy; it only
//  executes the C FFI call that corresponds to the request variant.
//

import Foundation

/// Transport configuration for one proxy start attempt.
enum VeilTransportRequest: Sendable {
    /// WebTunnel (VEIL v2): HTTP CONNECT-style upgrade over TLS.
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
enum VeilProxyRuntimeError: Error, Sendable {
    /// Rust returned code 2 — local network interface is unreachable.
    case networkUnreachable
    /// Any non-zero return code other than `networkUnreachable`. `reason` carries
    /// the real failing stage from `veil_last_error` (e.g. "veil-front: timeout
    /// after 7003ms"), or nil when none was available.
    case startFailed(code: Int32, reason: String?)

    var userFacingMessage: String {
        switch self {
        case .networkUnreachable: return "Failed to start proxy (network unreachable)"
        case .startFailed(let code, let reason):
            if let reason, !reason.isEmpty { return reason }
            return "Failed to start proxy (code \(code))"
        }
    }
}

// MARK: - Unified VEIL coordinator FFI

/// Which obfuscator won the happy-eyeballs probe race inside the Rust coordinator.
/// Mirrors `VeilStartResult.method` from the C FFI.
enum VeilMethod: UInt8, Sendable, Equatable {
    case obfs4 = 0
    case webTunnel = 1
    case masque = 2
    /// veil-front (honest-front HTTPS, sketch v2). Requires a per-relay ticket
    /// supplied via `VeilRelay.veilFrontTicket`; if the ticket is missing or the
    /// `VeilProxyStore.veilFrontEnabled` flag is off, Rust excludes veil-front
    /// from the probe race (its ticket-parse step fails the probe fast).
    case veilFront = 3

    var label: String {
        switch self {
        case .obfs4:     return "obfs4"
        case .webTunnel: return "webtunnel"
        case .masque:    return "masque"
        case .veilFront: return "veil-front"
        }
    }
}

/// Result of a single unified `veil_start` call.
struct VeilStartOutcome: Sendable, Equatable {
    let port: UInt16
    let method: VeilMethod
    let latencyMs: UInt32
}
