//
//  IceConnectionState.swift
//  Construct Messenger
//

import Foundation

/// Explicit ICE connection states replacing implicit boolean flag combinations.
///
/// Current transition graph:
///
/// ```text
/// off      -> active(port, webTunnel)
/// off      -> standby(port)
/// off      -> cooldown
/// standby  -> active(port, webTunnel)
/// standby  -> off
/// active   -> off
/// active   -> cooldown
/// cooldown -> off
/// ```
///
/// Today `IceProxyManager` still exposes legacy published flags for UI compatibility.
/// This enum is the target source of truth for the next reducer-based refactor step.
enum IceConnectionState: Equatable {
    /// No proxy running; gRPC routes direct or ICE is not available.
    case off
    /// ICE proxy pre-warming in standby. The proxy is running, but gRPC is not routed through it yet.
    case standby(port: UInt16)
    /// ICE proxy is active and gRPC routes through it.
    case active(port: UInt16, webTunnel: Bool)
    /// Exponential-backoff cooldown after consecutive failures.
    case cooldown
}
