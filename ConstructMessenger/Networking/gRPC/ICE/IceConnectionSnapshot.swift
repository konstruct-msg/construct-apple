//
//  IceConnectionSnapshot.swift
//  Construct Messenger
//
//  Derived snapshot of ICE connection state for UI and hot-path consumers.
//

import Foundation

/// Read-only snapshot of ICE connection state.
///
/// This type bridges the state machine (`IceConnectionState`) to legacy
/// consumers that expect boolean flags and published properties. It is
/// derived purely from state and contains no logic.
struct IceConnectionSnapshot: Equatable {
    /// Whether the ICE proxy is currently running (active or standby).
    let isRunning: Bool
    
    /// Local TCP port the proxy is listening on, or 0 if not running.
    let proxyPort: UInt16
    
    /// Whether the active transport is WebTunnel (ICE v2) rather than obfs4.
    let isWebTunnelActive: Bool
    
    /// Whether ICE is running in standby pre-warm mode (proxy up, but gRPC routes direct).
    let isStandbyPrewarm: Bool
    
    /// Whether ICE is in cooldown after a failure.
    let isOnCooldown: Bool
    
}
