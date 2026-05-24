//
//  IceConnectionEvent.swift
//  Construct Messenger
//
//  Events that drive ICE connection state transitions.
//

import Foundation

/// Events that trigger ICE connection state transitions.
///
/// These events are fed into `IceConnectionReducer.reduce` to produce
/// the next `IceConnectionState`. The reducer is pure and testable.
enum IceConnectionEvent: Equatable {
    // MARK: - Lifecycle
    
    /// User or system requested ICE to start.
    case startRequested(mode: IceMode)
    /// User or system requested ICE to stop.
    case stopRequested
    /// Mode changed (e.g. .auto → .on).
    case modeChanged(old: IceMode, new: IceMode)
    
    // MARK: - Proxy Start/Stop
    
    /// Native proxy started successfully on the given endpoint.
    case proxyStarted(port: UInt16, webTunnel: Bool)
    /// Native proxy start failed with the given error.
    case proxyStartFailed(error: String)
    /// Native proxy stopped.
    case proxyStopped
    
    // MARK: - Standby Pre-warm

    /// Coordinator decided the running proxy should be in standby (suppresses iceProxyPort).
    case standbyPrewarmCompleted(port: UInt16, webTunnel: Bool)

    // MARK: - DPI Auto-Mode

    /// DPI detection confirmed — promote from standby to active.
    case dpiConfirmed
    /// Direct connection verified — may demote or keep standby.
    case directVerified
    /// Direct connection blocked — activate ICE.
    case directBlocked
    
    // MARK: - Failures
    
    /// Relay failed with the given reason.
    case relayFailed(address: String, reason: IceFailureReason)
    /// WebTunnel blocked on active relay — will retry via obfs4.
    case webTunnelBlocked(address: String)
    /// Cert refresh succeeded — proxy may restart.
    case certRefreshSucceeded
    /// Cert refresh failed — no cert available.
    case certRefreshFailed
    /// Relay rotated to a new address.
    case relayRotated(address: String)
    
    // MARK: - Cooldown
    
    /// Cooldown started for the given duration.
    case cooldownStarted(duration: TimeInterval)
    /// Cooldown expired — ICE can resume.
    case cooldownExpired
    
    // MARK: - Network Changes
    
    /// Network path changed (WiFi ↔ cellular, interface change).
    case networkPathChanged(kind: NetworkChangeKind)
    /// Active proxy process died unexpectedly.
    case foregroundProxyDead
    /// Server retired the active relay (manifest eviction).
    case serverRetiredActiveRelay
}

/// Network change kind for ICE state machine events.
enum NetworkChangeKind: Equatable {
    case newInterface
    case interfaceRemoved
    case connectivityChanged
}
