//
//  VeilTrafficPath.swift
//  Construct Messenger
//

import Foundation

/// Describes the current effective traffic routing path.
/// Used for the Network Settings connection route indicator.
enum TrafficPath: Equatable {
    /// Direct TLS gRPC, no VEIL obfuscation.
    case direct
    /// VEIL veil-front: TLS 1.3 → honest-front HTTPS relay → backend.
    /// The active obfuscation transport on iOS.
    case veilFront(relay: String)
    /// VEIL v2 WebTunnel: TLS -> WebSocket -> relay -> server. (legacy, non-utls)
    case veilWebTunnel(relay: String)
    /// VEIL is enabled but proxy is temporarily bypassed after a failure.
    case veilCooldown
    /// VEIL is enabled but the proxy has not started yet.
    case veilConnecting

    var displayTitle: String {
        switch self {
        case .direct:           return "Direct gRPC"
        case .veilFront:         return "VEIL (veil-front)"
        case .veilWebTunnel:     return "VEIL v2 (WebTunnel)"
        case .veilCooldown:      return "Direct gRPC (VEIL recovering)"
        case .veilConnecting:    return "VEIL (Connecting…)"
        }
    }

    var displayDetail: String {
        #if DEBUG || INTERNAL_TOOLS
        // Internal builds: full transport detail for diagnostics.
        switch self {
        case .direct:                  return "TLS 1.3 ams.konstruct.cc:443"
        case .veilFront(let relay):     return "TLS 1.3 → veil-front → \(relay)"
        case .veilWebTunnel(let relay): return "wss://\(relay)"
        case .veilCooldown:             return "Reconnecting via VEIL…"
        case .veilConnecting:           return "Establishing veil-front tunnel…"
        }
        #else
        // External build (silent-transport-ui decision): never disclose transport, path, host, or
        // whether the user is routing around censorship. Direct and VEIL collapse to one neutral
        // state so the UI is an identical, information-free "Protected".
        switch self {
        case .direct, .veilFront, .veilWebTunnel:
            return NSLocalizedString("net_status_protected", comment: "Neutral connected indicator — no transport disclosed")
        case .veilCooldown, .veilConnecting:
            return NSLocalizedString("net_status_connecting", comment: "Neutral connecting indicator")
        }
        #endif
    }

    /// Color name for SwiftUI consumers without importing SwiftUI into every caller.
    var color: String {
        switch self {
        case .direct:        return "blue"
        case .veilFront:      return "green"
        case .veilWebTunnel:  return "teal"
        case .veilCooldown:   return "orange"
        case .veilConnecting: return "orange"
        }
    }
}
