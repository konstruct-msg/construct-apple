//
//  IceConnectionReducer.swift
//  Construct Messenger
//
//  Pure reducer function for ICE connection state transitions.
//

import Foundation

/// Pure state machine reducer for ICE connection lifecycle.
///
/// This type contains no state and performs no I/O. It applies events
/// to the current state and returns the next state. All side effects
/// (proxy start/stop, network calls) are handled by the coordinator.
enum IceConnectionReducer {
    /// Apply an event to the current state and return the next state.
    ///
    /// - Parameters:
    ///   - state: Current ICE connection state.
    ///   - event: Event to apply.
    /// - Returns: New state after applying the event.
    static func reduce(state: IceConnectionState, event: IceConnectionEvent) -> IceConnectionState {
        switch (state, event) {
        // ── Lifecycle ───────────────────────────────────────────────────────────
        case (_, .startRequested):
            return state

        case (_, .stopRequested):
            return .off

        case (_, .modeChanged):
            return state

        // ── Proxy Start/Stop ────────────────────────────────────────────────────
        case (.off, .proxyStarted(let port, let webTunnel)):
            return .active(port: port, webTunnel: webTunnel)

        case (.standby, .proxyStarted(let port, let webTunnel)):
            // Standby proxy restarted (e.g. after rotation) — stay standby with new port.
            return .standby(port: port, webTunnel: webTunnel)

        case (.active, .proxyStarted(let port, let webTunnel)):
            return .active(port: port, webTunnel: webTunnel)

        case (.cooldown, .proxyStarted):
            // Proxy started during cooldown — wait for expiry before going active.
            return .cooldown

        case (_, .proxyStartFailed):
            return .off

        case (_, .proxyStopped):
            return .off

        // ── Standby Pre-warm ────────────────────────────────────────────────────
        case (_, .standbyPrewarmCompleted(let port, let webTunnel)):
            // Coordinator placed the running proxy in standby; gRPC stays direct.
            return .standby(port: port, webTunnel: webTunnel)

        // ── DPI Auto-Mode ───────────────────────────────────────────────────────
        case (.standby(let port, let webTunnel), .dpiConfirmed):
            return .active(port: port, webTunnel: webTunnel)

        case (.standby(let port, let webTunnel), .directBlocked):
            return .active(port: port, webTunnel: webTunnel)

        case (.standby, .directVerified):
            return state

        case (.active, .directVerified), (.off, .directBlocked):
            return state

        // ── Failures ────────────────────────────────────────────────────────────
        case (.active, .relayFailed):
            return .cooldown

        case (.active, .foregroundProxyDead):
            return .cooldown

        case (.standby, .foregroundProxyDead):
            return .off

        case (.active, .webTunnelBlocked),
             (.active, .certRefreshSucceeded),
             (.active, .relayRotated):
            return state

        case (_, .certRefreshFailed), (_, .serverRetiredActiveRelay):
            return state

        // ── Cooldown ────────────────────────────────────────────────────────────
        case (.cooldown, .cooldownStarted):
            return state

        case (_, .cooldownStarted):
            return .cooldown

        case (.cooldown, .cooldownExpired), (.off, .cooldownExpired):
            return .off

        // ── Network Changes ─────────────────────────────────────────────────────
        case (.active, .networkPathChanged),
             (.standby, .networkPathChanged),
             (.off, .networkPathChanged),
             (.cooldown, .networkPathChanged):
            return .off

        // ── Default: ignore unhandled (state, event) combinations ───────────────
        default:
            return state
        }
    }
    
    /// Derive a UI/hot-path compatible snapshot from the current state.
    ///
    /// This bridges the state machine to legacy consumers that expect
    /// `isRunning`, `proxyPort`, `isWebTunnelActive`, etc.
    static func snapshot(state: IceConnectionState) -> IceConnectionSnapshot {
        switch state {
        case .off:
            return IceConnectionSnapshot(
                isRunning: false,
                proxyPort: 0,
                isWebTunnelActive: false,
                isStandbyPrewarm: false,
                isOnCooldown: false
            )
        case .standby(let port, _):
            return IceConnectionSnapshot(
                isRunning: true,
                proxyPort: port,
                isWebTunnelActive: false,
                isStandbyPrewarm: true,
                isOnCooldown: false
            )
        case .active(let port, let webTunnel):
            return IceConnectionSnapshot(
                isRunning: true,
                proxyPort: port,
                isWebTunnelActive: webTunnel,
                isStandbyPrewarm: false,
                isOnCooldown: false
            )
        case .cooldown:
            return IceConnectionSnapshot(
                isRunning: false,
                proxyPort: 0,
                isWebTunnelActive: false,
                isStandbyPrewarm: false,
                isOnCooldown: true
            )
        }
    }
}
