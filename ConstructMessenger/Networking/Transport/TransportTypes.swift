//
//  TransportTypes.swift
//  Construct Messenger
//
//  Foundation types for the unified transport routing layer.
//
//  Design goals:
//  • All transport decisions are expressed as transitions of a single FSM.
//  • The reducer is a pure function (state, event, config, now) -> (state, [Effect]).
//  • All types are Sendable so the FSM can be driven from an actor without ceremony.
//  • No reference to gRPC, VEIL proxy, or any specific I/O — that lives in effectors.
//

import Foundation

// MARK: - Target

/// What transport the next RPC should go through.
///
/// `veil` always implies a local proxy listening at `127.0.0.1:port` that forwards
/// to the named relay. `direct` is a TLS handshake straight to the configured server.
enum TransportTarget: Equatable, Sendable {
    case direct(DirectProtocol)
    case veil(port: UInt16, relay: String)

    var isVEIL: Bool {
        if case .veil = self { return true }
        return false
    }
}

enum DirectProtocol: Equatable, Sendable {
    case h2
    case h3
}

// MARK: - State

/// The single source of truth for the transport layer.
///
/// Mutually exclusive cases — at any moment the system is in exactly one state.
/// The reducer enforces all legal transitions; no field is mutated outside the reducer.
enum TransportState: Equatable, Sendable {
    /// Network reachability reports no usable interface.
    case offline

    /// Using the direct path. `consecutiveFails` tracks how many transport-level
    /// failures occurred in a row; reaching `TransportConfig.directFailThreshold`
    /// transitions to `veilProbing`.
    case direct(consecutiveFails: Int)

    /// Asking the proxy effector to bring up an VEIL relay. `attempt` is the 1-based
    /// attempt number within the current probing session; on `maxProbeAttempts` we
    /// give up and enter `veilCooldown`.
    case veilProbing(attempt: Int)

    /// VEIL proxy is running and has served at least one transport event without failure.
    case veilActive(relay: String, port: UInt16, since: Date)

    /// VEIL proxy is running but recent traffic has failed. After
    /// `veilDegradedFailThreshold` consecutive failures we rotate via `veilProbing`.
    case veilDegraded(relay: String, port: UInt16, consecutiveFails: Int)

    /// All probing attempts failed; suspended until `until`. Then we drop back to direct.
    case veilCooldown(until: Date)

    /// Whether the next outgoing RPC should use the VEIL proxy.
    var prefersVEIL: Bool {
        switch self {
        case .veilProbing, .veilActive, .veilDegraded:
            return true
        case .offline, .direct, .veilCooldown:
            return false
        }
    }

    /// The current relay address, if any.
    var currentRelay: String? {
        switch self {
        case .veilActive(let r, _, _), .veilDegraded(let r, _, _):
            return r
        case .offline, .direct, .veilProbing, .veilCooldown:
            return nil
        }
    }

    /// The current VEIL proxy port, if any (nil when no proxy is running).
    var veilPort: UInt16? {
        switch self {
        case .veilActive(_, let p, _), .veilDegraded(_, let p, _):
            return p
        case .offline, .direct, .veilProbing, .veilCooldown:
            return nil
        }
    }

    /// Short label for UI / logs.
    var shortLabel: String {
        switch self {
        case .offline:                              return "offline"
        case .direct(let f):                        return "direct(fails=\(f))"
        case .veilProbing(let a):                    return "veil-probing(attempt=\(a))"
        case .veilActive(let r, _, _):               return "veil-active(\(r))"
        case .veilDegraded(let r, _, let f):         return "veil-degraded(\(r), fails=\(f))"
        case .veilCooldown(let until):               return "veil-cooldown(until=\(Int(until.timeIntervalSinceNow))s)"
        }
    }
}

// MARK: - RPC failure classification

/// Transport-layer classification of an RPC failure. Decouples the reducer from gRPC types.
///
/// The classifier (`VeilFailurePolicy`-style) lives outside the FSM and translates raw errors
/// into one of these kinds before posting an event. The FSM never sees `RPCError`.
enum RPCFailureKind: Sendable, Equatable {
    /// Client-side timeout / cooperative cancellation. Connection is not broken.
    case transientCancellation
    /// Clean server-side `.unauthenticated` / `.permissionDenied`.
    /// On direct path: real rejection. On ICE: may be relay forgery — handled outside FSM.
    case authRejected
    /// Application-layer error (validation, not-found, etc.). Reducer ignores.
    case applicationError
    /// TLS alert 40 / handshake failure — relay's TLS fingerprint is being blocked.
    case tlsFingerprintBlocked
    /// TLS certificate expired or unverified.
    case tlsCertExpired
    /// WebTunnel relay returned a decoy 404 / non-101 — transparent proxy interfering.
    case webTunnelBlocked
    /// ECONNREFUSED on the local VEIL proxy — Rust process is dead.
    case staleLocalProxy
    /// gRPC deadline exceeded.
    case streamTimeout
    /// Generic transport-level failure (NWError, POSIXError, unknown).
    case transportUnknown

    /// True when this failure should drive FSM transitions. False for application-layer
    /// failures that the transport router should ignore.
    var isTransportFailure: Bool {
        switch self {
        case .applicationError, .authRejected, .transientCancellation:
            return false
        default:
            return true
        }
    }
}

// MARK: - Event

/// Inputs to the FSM. Every external interaction with the transport layer is one of these.
enum TransportEvent: Sendable, Equatable {
    /// An RPC completed successfully via `target` in `latencyMs` milliseconds.
    case rpcSucceeded(via: TransportTarget, latencyMs: Int)

    /// An RPC failed.
    /// - foreground: true for user-visible flows; false for background prefetch/maintenance.
    case rpcFailed(kind: RPCFailureKind, via: TransportTarget, foreground: Bool)

    /// Network path changed (interface switch, VPN on/off, reachability flip).
    /// Carries the up-to-date snapshot of inputs the FSM needs to recompute its
    /// starting state — keeps the reducer pure.
    case networkPathChanged(reachable: Bool, censored: Bool, mode: VeilMode)

    /// User toggled VEIL mode in settings.
    /// `censored` carries the current detector reading so the reducer can decide
    /// whether `.auto` should activate VEIL immediately (true) or wait for failures (false).
    case veilModeChanged(VeilMode, censored: Bool)

    /// Server-pushed cert or relay manifest changed; force VEIL to restart if active.
    /// No-op when on the direct path.
    case veilConfigChanged

    /// Effector reports the proxy successfully bound a port for `relay`.
    /// `restarted` is true when a fresh proxy instance was started (port may be reused).
    case proxyStarted(relay: String, port: UInt16, restarted: Bool)

    /// Effector reports proxy start failed. `relay` may be nil if no relay was selectable.
    case proxyStartFailed(relay: String?, reason: String)

    /// Cooldown timer fired.
    case cooldownElapsed

    /// User-triggered "reset everything" (settings → reset, or pull-to-refresh).
    case manualReset
}

// MARK: - Effect

/// Side-effects requested by the reducer. Effectors apply them; the FSM itself never does I/O.
enum TransportEffect: Equatable, Sendable {
    /// Drop the persistent gRPC client; the next RPC will create a fresh one.
    case invalidateGRPCClient

    /// Set (or clear, when nil) the local VEIL proxy port that gRPC routes to.
    case setVeilPort(UInt16?)

    /// Ask the proxy effector to select a relay and start the proxy. The effector
    /// will eventually post `proxyStarted` or `proxyStartFailed` back to the router.
    case requestProxyStart

    /// Stop the proxy unconditionally.
    case requestProxyStop

    /// Schedule a `cooldownElapsed` event to fire at the given date.
    case scheduleCooldownEnd(at: Date)
}

// MARK: - Config

/// Thresholds and constants used by the reducer. Held by the router and passed to the
/// reducer on every call so they're trivially overridable in tests.
struct TransportConfig: Sendable, Equatable {
    /// Direct-path transport failures before we escalate to VEIL.
    var directFailThreshold: Int = 2

    /// VEIL-path transport failures on the same relay before we rotate.
    var veilDegradedFailThreshold: Int = 2

    /// How many relays to try before falling into cooldown.
    var maxProbeAttempts: Int = 3

    /// Seconds spent in cooldown after exhausting probing attempts.
    var veilCooldownDuration: TimeInterval = 30

    static let `default` = TransportConfig()
}

// MARK: - Initial state computation

extension TransportState {
    /// Computes the starting state for a freshly created router.
    static func initial(mode: VeilMode, censored: Bool, reachable: Bool) -> TransportState {
        guard reachable else { return .offline }
        switch mode {
        case .off:
            return .direct(consecutiveFails: 0)
        case .on:
            return .veilProbing(attempt: 1)
        case .auto:
            return censored ? .veilProbing(attempt: 1) : .direct(consecutiveFails: 0)
        }
    }
}

// MARK: - Transition log

/// One entry in the router's ring buffer of recent state transitions.
/// Used by the debug-UI Transport Diagnostics screen and dumped in support logs.
struct TransitionLogEntry: Sendable, Equatable {
    let at: Date
    let from: TransportState
    let to: TransportState
    let event: String
    let cause: String
    let effects: [String]

    var oneLine: String {
        let ts = DateFormatter.transitionLog.string(from: at)
        let arrow = from == to ? "•" : "→"
        return "[\(ts)] \(from.shortLabel) \(arrow) \(to.shortLabel) | event=\(event)\(cause.isEmpty ? "" : " cause=\(cause)")\(effects.isEmpty ? "" : " effects=[\(effects.joined(separator: ","))]")"
    }
}

private extension DateFormatter {
    static let transitionLog: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
