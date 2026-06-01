//
//  ConnectionStatusManager.swift
//  Construct Messenger
//
//  Single-source-of-truth wrapper around TransportRouterMirror's state.
//  `connectionStatus` is recomputed by exactly one internal observer; all
//  former external writers (`markStream*`, `markConnecting`, `markRequestFailed`)
//  are removed in favour of FSM-driven derivation.
//

import Foundation

/// Publishes a coarse connection status derived from the transport FSM.
///
/// Inputs to the derivation:
/// 1. `TransportRouterMirror.shared.state` — the FSM truth.
/// 2. `NetworkReachabilityManager.shared.isReachable` — fast-path offline detection.
/// 3. `lastSuccessfulRequest` — used as a 90s grace window so a single stream
///    reconnect cycle doesn't flicker the UI from Connected → Connecting → Connected.
///
/// The only external entry points that *mutate* state are:
/// - `markRequestSucceeded()` — bumps `lastSuccessfulRequest`, clears `lastError`.
/// - `setLastError(_:)` — surfaces the most recent failure reason to UI.
/// - `markStreamPaused/Resumed()` — orthogonal app-lifecycle flag (background pause).
@MainActor
@Observable
class ConnectionStatusManager {
    static let shared = ConnectionStatusManager()

    /// Current connection status. Derived; do not assign from outside.
    private(set) var connectionStatus: ConnectionStatus = .unknown

    /// Short diagnostic string for the "Connecting…" phase, e.g. "VEIL probe 2".
    /// Derived from the current FSM state; nil when `.connected` or `.disconnected`.
    private(set) var connectingPhase: String?

    /// True when the stream is intentionally paused (app in background).
    /// Visually distinct from "connecting" in the status indicator. Orthogonal to FSM state.
    private(set) var isStreamPaused: Bool = false

    /// Convenience property for checking if connected.
    var isConnected: Bool { connectionStatus == .connected }

    /// Last successful API request timestamp. Drives the 90s grace window.
    private(set) var lastSuccessfulRequest: Date?

    /// Last error message if any. Set by the transport effector on failure events.
    private(set) var lastError: String?

    private var recomputeTask: Task<Void, Never>?
    private var graceExpiryTask: Task<Void, Never>?
    private let reachabilityManager = NetworkReachabilityManager.shared

    /// Grace window: keep showing `.connected` for this long after the last successful RPC,
    /// even if the bidi stream restarts in the meantime. 90s covers the worst-case observed
    /// VEIL stream reconnect cycle (~50s connection life + ~20s reconnect attempt) and prevents
    /// flicker on healthy underlying transports.
    private static let connectedGraceWindow: TimeInterval = 90

    enum ConnectionStatus: Equatable {
        case connected
        case disconnected
        case connecting
        case unknown

        var displayText: String {
            switch self {
            case .connected: return "Connected"
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting..."
            case .unknown: return "Unknown"
            }
        }

        var localizedKey: String {
            switch self {
            case .connected: return "connected"
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .unknown: return "unknown"
            }
        }
    }

    private init() {
        recompute()
        startRecomputeLoop()
    }

    // MARK: - Recompute loop (single writer)

    private func startRecomputeLoop() {
        recomputeTask = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        guard let self else { return }
                        _ = TransportRouterMirror.shared.state
                        _ = self.reachabilityManager.isReachable
                        _ = self.lastSuccessfulRequest
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.recompute()
                }
            }
        }
    }

    private func recompute() {
        let oldStatus = connectionStatus
        let oldPhase = connectingPhase

        let mirrorState = TransportRouterMirror.shared.state
        let reachable = reachabilityManager.isReachable
        let hasRecentRpc: Bool = {
            guard let last = lastSuccessfulRequest else { return false }
            return Date().timeIntervalSince(last) <= Self.connectedGraceWindow
        }()

        let newStatus: ConnectionStatus
        if !reachable {
            newStatus = .disconnected
        } else {
            switch mirrorState {
            case .offline:
                newStatus = .disconnected
            case .direct(let fails):
                if fails == 0 {
                    newStatus = hasRecentRpc ? .connected : .connecting
                } else {
                    newStatus = .connecting
                }
            case .veilActive:
                newStatus = hasRecentRpc ? .connected : .connecting
            case .veilProbing, .veilDegraded, .veilCooldown:
                newStatus = .connecting
            }
        }

        let newPhase: String? = newStatus == .connecting ? phaseLabel(for: mirrorState, reachable: reachable) : nil

        if newStatus != oldStatus {
            connectionStatus = newStatus
            Log.info("Status: \(oldStatus.displayText) → \(newStatus.displayText) (state=\(mirrorState.shortLabel), recentRpc=\(hasRecentRpc))", category: "ConnectionStatus")
        }
        if newPhase != oldPhase {
            connectingPhase = newPhase
        }
    }

    private func phaseLabel(for state: TransportState, reachable: Bool) -> String? {
        guard reachable else { return nil }
        switch state {
        case .offline:
            return nil
        case .direct(let fails) where fails > 0:
            return "retry direct (\(fails))"
        case .direct:
            return nil
        case .veilProbing(let attempt):
            return "VEIL probe \(attempt)"
        case .veilActive(let relay, _, _):
            return "VEIL \(relay)"
        case .veilDegraded(let relay, _, let fails):
            return "VEIL degraded \(relay) (\(fails))"
        case .veilCooldown(let until):
            let secs = max(0, Int(until.timeIntervalSinceNow))
            return "VEIL cooldown (\(secs)s)"
        }
    }

    // MARK: - External mutation surface (intentionally small)

    /// Marks a successful unary RPC. Bumps the grace window and clears the last error.
    /// The only legitimate external mutation, called from MessageStreamManager unary success
    /// paths and from `ConnectionStatusEffector` on every `rpcSucceeded` FSM event.
    func markRequestSucceeded() {
        lastSuccessfulRequest = Date()
        lastError = nil
        // Schedule a recompute when the grace window expires, so status flips to
        // .connecting if no further RPCs land before then.
        graceExpiryTask?.cancel()
        graceExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectedGraceWindow + 1))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.recompute() }
        }
    }

    /// Surfaces a failure reason for diagnostic UI. Called by the transport effector
    /// on `proxyStartFailed` / `rpcFailed` events. Does not affect status — that's derived.
    func setLastError(_ message: String?) {
        lastError = message
    }

    /// App-lifecycle flag. Stream is paused when the app is in background.
    func markStreamPaused() { isStreamPaused = true }
    func markStreamResumed() { isStreamPaused = false }

    /// True if there was no successful RPC in the last `threshold` seconds.
    /// Used by callers that want to check freshness without subscribing to status.
    func isConnectionStale(threshold: TimeInterval = 60) -> Bool {
        guard let lastRequest = lastSuccessfulRequest else { return true }
        return Date().timeIntervalSince(lastRequest) > threshold
    }
}
