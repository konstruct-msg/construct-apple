//
//  IceTrafficPath.swift
//  Construct Messenger
//

import Foundation

/// Describes the current effective traffic routing path.
/// Used for the Network Settings connection route indicator.
enum TrafficPath: Equatable {
    /// Direct TLS gRPC, no ICE obfuscation.
    case direct
    /// ICE primary: TLS 1.3 -> obfs4 -> Amsterdam via Traefik.
    case icePrimary(host: String)
    /// ICE relay: plain obfs4 -> relay -> Amsterdam.
    case iceRelay(address: String)
    /// ICE v2 WebTunnel: TLS -> WebSocket -> relay -> server.
    case iceWebTunnel(relay: String)
    /// ICE is enabled but proxy is temporarily bypassed after a failure.
    case iceCooldown
    /// ICE is enabled but the proxy has not started yet.
    case iceConnecting

    var displayTitle: String {
        switch self {
        case .direct:           return "Direct gRPC"
        case .icePrimary:       return "ICE (Primary)"
        case .iceRelay:         return "ICE (Relay)"
        case .iceWebTunnel:     return "ICE v2 (WebTunnel)"
        case .iceCooldown:      return "Direct gRPC (ICE recovering)"
        case .iceConnecting:    return "ICE (Connecting…)"
        }
    }

    var displayDetail: String {
        switch self {
        case .direct:                  return "TLS 1.3 · ams.konstruct.cc:443"
        case .icePrimary(let host):    return "TLS + obfs4 · \(host)"
        case .iceRelay(let address):   return "obfs4 relay · \(address)"
        case .iceWebTunnel(let relay): return "wss:// · \(relay)"
        case .iceCooldown:             return "Reconnecting via ICE…"
        case .iceConnecting:           return "Starting obfs4 proxy…"
        }
    }

    var symbolName: String {
        switch self {
        case .direct:        return "network"
        case .icePrimary:    return "lock.shield.fill"
        case .iceRelay:      return "arrow.triangle.2.circlepath.circle.fill"
        case .iceWebTunnel:  return "lock.shield.fill"
        case .iceCooldown:   return "exclamationmark.arrow.circlepath"
        case .iceConnecting: return "clock.arrow.circlepath"
        }
    }

    /// Color name for SwiftUI consumers without importing SwiftUI into every caller.
    var color: String {
        switch self {
        case .direct:        return "blue"
        case .icePrimary:    return "green"
        case .iceRelay:      return "purple"
        case .iceWebTunnel:  return "teal"
        case .iceCooldown:   return "orange"
        case .iceConnecting: return "orange"
        }
    }
}
