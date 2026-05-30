//
//  ConnectionStatusManager.swift
//  Construct Messenger
//
//  Manages connection status for gRPC stream architecture
//

import Foundation

/// Manages and publishes connection status for the app
/// In gRPC architecture, connection status is based on:
/// 1. Network reachability (device has internet)
/// 2. gRPC MessageStream connection state
/// 3. Session validity
@MainActor
@Observable
class ConnectionStatusManager {
    static let shared = ConnectionStatusManager()

    /// Current connection status
    var connectionStatus: ConnectionStatus = .unknown

    /// Short diagnostic string for the "Connecting…" phase, e.g. "H3 → H2 fallback (attempt 2)".
    /// Cleared when `connected` or `disconnected`.
    private(set) var connectingPhase: String?

    /// True when the stream is intentionally paused (app in background).
    /// Visually distinct from "connecting" in the status indicator.
    private(set) var isStreamPaused: Bool = false

    /// Convenience property for checking if connected
    var isConnected: Bool {
        connectionStatus == .connected
    }

    /// Last successful API request timestamp
    private(set) var lastSuccessfulRequest: Date?

    /// Last error message if any
    private(set) var lastError: String?

    private var reachabilityTask: Task<Void, Never>?
    private var veilProxyObserver: NSObjectProtocol?
    private let reachabilityManager = NetworkReachabilityManager.shared

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
        setupReachabilityObserving()
        setupICEProxyObserving()

        // Initial status based on network reachability
        // If network is reachable, we're in "connecting" state until first successful request
        // If network is not reachable, we're "disconnected"
        if reachabilityManager.isReachable {
            connectionStatus = .connecting
            Log.info("ConnectionStatusManager initialized: Connecting (network reachable)", category: "ConnectionStatus")
        } else {
            connectionStatus = .disconnected
            Log.info("ConnectionStatusManager initialized: Disconnected (no network)", category: "ConnectionStatus")
        }
    }

    // MARK: - Setup

    private func setupReachabilityObserving() {
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Wait for isReachable to change, then handle
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.reachabilityManager.isReachable
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.handleReachabilityChange(isReachable: self.reachabilityManager.isReachable)
                }
            }
        }
    }

    /// Observe ICE proxy state — if the proxy dies while we're on ICE, immediately
    /// transition to "connecting" so the UI doesn't show a false "Connected" status.
    private func setupICEProxyObserving() {
        veilProxyObserver = NotificationCenter.default.addObserver(
            forName: .veilProxyStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isRunning = (notification.userInfo?["isRunning"] as? Bool) ?? false
            Task { @MainActor [weak self] in
                self?.handleICEProxyStateChange(isRunning: isRunning)
            }
        }
    }

    private func handleICEProxyStateChange(isRunning: Bool) {
        guard !isRunning, connectionStatus == .connected else { return }
        // Proxy just stopped while we thought we were connected.
        // The stream hasn't noticed yet (heartbeat timeout = 75s), so we
        // proactively downgrade to "connecting" to avoid a false-positive UI.
        connectionStatus = .connecting
        connectingPhase = "ICE proxy stopped — reconnecting"
        Log.info("ICE proxy stopped while connected — status → Connecting", category: "ConnectionStatus")
    }

    // MARK: - Status Updates

    private func handleReachabilityChange(isReachable: Bool) {
        let oldStatus = connectionStatus
        
        if !isReachable {
            connectionStatus = .disconnected
            lastError = "No network connection"
        } else if connectionStatus == .disconnected {
            // Network is back, but we need to verify server connectivity
            connectionStatus = .connecting
            lastError = nil
        }
        
        if oldStatus != connectionStatus {
            Log.info("Network reachability changed: \(oldStatus.displayText) -> \(connectionStatus.displayText)", category: "ConnectionStatus")
        }
    }

    func markRequestSucceeded() {
        let oldStatus = connectionStatus
        lastSuccessfulRequest = Date()
        lastError = nil
        connectingPhase = nil
        connectionStatus = .connected
        if oldStatus != .connected {
            Log.info("Connection status changed: \(oldStatus.displayText) -> Connected", category: "ConnectionStatus")
        }
    }

    func markRequestFailed(error: String? = nil, isCritical: Bool = false) {
        let oldStatus = connectionStatus
        lastError = error

        if !reachabilityManager.isReachable {
            connectionStatus = .disconnected
        } else if isCritical {
            if connectionStatus == .connected {
                connectionStatus = .connecting
            }
        } else {
            if connectionStatus == .connected {
                let gracePeriod: TimeInterval = 120
                if !isConnectionStale(threshold: gracePeriod) {
                    Log.debug("Non-critical error, but staying Connected (last success was recent)", category: "ConnectionStatus")
                    return
                } else {
                    connectionStatus = .connecting
                }
            }
        }

        if oldStatus != connectionStatus {
            Log.info("Connection status changed: \(oldStatus.displayText) -> \(connectionStatus.displayText)", category: "ConnectionStatus")
            if let error = error {
                Log.info("Error: \(error)", category: "ConnectionStatus")
            }
        }
    }

    func markConnecting(phase: String? = nil) {
        if connectionStatus != .connected && connectionStatus != .connecting {
            connectionStatus = .connecting
        }
        if let phase { connectingPhase = phase }
    }

    // MARK: - gRPC Stream Integration

    func markStreamConnected() {
        let old = connectionStatus
        lastSuccessfulRequest = Date()
        lastError = nil
        connectingPhase = nil
        connectionStatus = .connected
        if old != .connected {
            Log.info("Stream connected → status: Connected", category: "ConnectionStatus")
            // Retry any avatars that failed to download while we were offline.
            AvatarRetryService.shared.retryPendingAvatarsIfNeeded()
        }
    }

    func markStreamDisconnected(error: String? = nil, phase: String? = nil) {
        lastError = error
        guard reachabilityManager.isReachable else {
            connectingPhase = nil
            connectionStatus = .disconnected
            return
        }
        // Stream disconnect doesn't necessarily mean we're offline — the gRPC channel
        // can still handle unary RPCs while the bidi stream reconnects. If we've had a
        // successful RPC in the last 90 seconds, treat the stream disconnect as transient
        // and keep showing Connected. Otherwise (no recent traffic) downgrade to Connecting.
        // 90s covers the worst-case observed ICE stream reconnect cycle (~50s connection
        // life + ~20s reconnect attempt). This stops the UI flickering Connected → Connecting
        // → Connected on every stream restart cycle when the underlying transport is healthy.
        if connectionStatus == .connected, !isConnectionStale(threshold: 90) {
            if let phase { connectingPhase = phase }
            return
        }
        if connectionStatus == .connected {
            connectionStatus = .connecting
            Log.info("Stream disconnected → status: Connecting", category: "ConnectionStatus")
        }
        if let phase { connectingPhase = phase }
    }

    func markStreamPaused() {
        isStreamPaused = true
    }

    func markStreamResumed() {
        isStreamPaused = false
    }

    /// Check if we should consider the connection stale
    /// (no successful request in the last N seconds)
    func isConnectionStale(threshold: TimeInterval = 60) -> Bool {
        guard let lastRequest = lastSuccessfulRequest else {
            return true
        }
        return Date().timeIntervalSince(lastRequest) > threshold
    }
}
