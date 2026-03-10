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

    /// Convenience property for checking if connected
    var isConnected: Bool {
        connectionStatus == .connected
    }

    /// Last successful API request timestamp
    private(set) var lastSuccessfulRequest: Date?

    /// Last error message if any
    private(set) var lastError: String?

    private var reachabilityTask: Task<Void, Never>?
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

        // Initial status based on network reachability
        // If network is reachable, we're in "connecting" state until first successful request
        // If network is not reachable, we're "disconnected"
        if reachabilityManager.isReachable {
            connectionStatus = .connecting
            Log.info("🔄 ConnectionStatusManager initialized: Connecting (network reachable)", category: "ConnectionStatus")
        } else {
            connectionStatus = .disconnected
            Log.info("🔴 ConnectionStatusManager initialized: Disconnected (no network)", category: "ConnectionStatus")
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
            Log.info("🌐 Network reachability changed: \(oldStatus.displayText) -> \(connectionStatus.displayText)", category: "ConnectionStatus")
        }
    }

    func markRequestSucceeded() {
        let oldStatus = connectionStatus
        lastSuccessfulRequest = Date()
        lastError = nil
        connectionStatus = .connected
        if oldStatus != .connected {
            Log.info("🟢 Connection status changed: \(oldStatus.displayText) -> Connected", category: "ConnectionStatus")
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
                    Log.debug("⚠️ Non-critical error, but staying Connected (last success was recent)", category: "ConnectionStatus")
                    return
                } else {
                    connectionStatus = .connecting
                }
            }
        }

        if oldStatus != connectionStatus {
            Log.info("🔴 Connection status changed: \(oldStatus.displayText) -> \(connectionStatus.displayText)", category: "ConnectionStatus")
            if let error = error {
                Log.info("   Error: \(error)", category: "ConnectionStatus")
            }
        }
    }

    func markConnecting() {
        if connectionStatus != .connected && connectionStatus != .connecting {
            connectionStatus = .connecting
        }
    }

    // MARK: - gRPC Stream Integration

    func markStreamConnected() {
        let old = connectionStatus
        lastSuccessfulRequest = Date()
        lastError = nil
        connectionStatus = .connected
        if old != .connected {
            Log.info("🟢 Stream connected → status: Connected", category: "ConnectionStatus")
        }
    }

    func markStreamDisconnected(error: String? = nil) {
        lastError = error
        if reachabilityManager.isReachable {
            if connectionStatus == .connected {
                connectionStatus = .connecting
                Log.info("🟡 Stream disconnected → status: Connecting", category: "ConnectionStatus")
            }
        } else {
            connectionStatus = .disconnected
        }
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
