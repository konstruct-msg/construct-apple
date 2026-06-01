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
    /// VEIL primary: TLS 1.3 -> obfs4 -> Amsterdam via Traefik.
    case veilPrimary(host: String)
    /// VEIL relay: plain obfs4 -> relay -> Amsterdam.
    case veilRelay(address: String)
    /// VEIL v2 WebTunnel: TLS -> WebSocket -> relay -> server.
    case veilWebTunnel(relay: String)
    /// VEIL is enabled but proxy is temporarily bypassed after a failure.
    case veilCooldown
    /// VEIL is enabled but the proxy has not started yet.
    case veilConnecting

    var displayTitle: String {
        switch self {
        case .direct:           return "Direct gRPC"
        case .veilPrimary:       return "VEIL (Primary)"
        case .veilRelay:         return "VEIL (Relay)"
        case .veilWebTunnel:     return "VEIL v2 (WebTunnel)"
        case .veilCooldown:      return "Direct gRPC (VEIL recovering)"
        case .veilConnecting:    return "VEIL (Connecting…)"
        }
    }

    var displayDetail: String {
        switch self {
        case .direct:                  return "TLS 1.3 ams.konstruct.cc:443"
        case .veilPrimary(let host):    return "TLS + obfs4 \(host)"
        case .veilRelay(let address):   return "obfs4 relay \(address)"
        case .veilWebTunnel(let relay): return "wss://\(relay)"
        case .veilCooldown:             return "Reconnecting via VEIL…"
        case .veilConnecting:           return "Starting obfs4 proxy…"
        }
    }
    
    /// Color name for SwiftUI consumers without importing SwiftUI into every caller.
    var color: String {
        switch self {
        case .direct:        return "blue"
        case .veilPrimary:    return "green"
        case .veilRelay:      return "purple"
        case .veilWebTunnel:  return "teal"
        case .veilCooldown:   return "orange"
        case .veilConnecting: return "orange"
        }
    }
}
