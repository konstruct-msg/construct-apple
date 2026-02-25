//
//  ConnectionStatusManager.swift
//  Construct Messenger
//
//  Manages connection status for REST API architecture
//  Replaces WebSocket-based connection status tracking
//

import Foundation
import Combine

/// Manages and publishes connection status for the app
/// In REST architecture, connection status is based on:
/// 1. Network reachability (device has internet)
/// 2. Last API request success/failure
/// 3. Session validity
class ConnectionStatusManager: ObservableObject {
    static let shared = ConnectionStatusManager()

    /// Current connection status
    @Published var connectionStatus: ConnectionStatus = .unknown

    /// Convenience property for checking if connected
    var isConnected: Bool {
        connectionStatus == .connected
    }

    /// Last successful API request timestamp
    @Published private(set) var lastSuccessfulRequest: Date?

    /// Last error message if any
    @Published private(set) var lastError: String?

    private var cancellables = Set<AnyCancellable>()
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
        // Observe network reachability changes
        reachabilityManager.$isReachable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReachable in
                self?.handleReachabilityChange(isReachable: isReachable)
            }
            .store(in: &cancellables)
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

    /// Call this when an API request succeeds
    func markRequestSucceeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let oldStatus = self.connectionStatus
            self.lastSuccessfulRequest = Date()
            self.lastError = nil
            self.connectionStatus = .connected
            
            if oldStatus != .connected {
                Log.info("🟢 Connection status changed: \(oldStatus.displayText) -> Connected", category: "ConnectionStatus")
            }
        }
    }

    /// Call this when an API request fails
    /// - Parameter error: Optional error description
    /// - Parameter isCritical: If true, immediately change status. If false, only change after grace period.
    func markRequestFailed(error: String? = nil, isCritical: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let oldStatus = self.connectionStatus
            self.lastError = error

            // Only mark as disconnected if network is unreachable
            if !self.reachabilityManager.isReachable {
                self.connectionStatus = .disconnected
            } else if isCritical {
                // Critical errors (auth failures, etc.) should immediately change status
                if self.connectionStatus == .connected {
                    self.connectionStatus = .connecting
                }
            } else {
                // Non-critical errors (timeouts, temporary failures):
                // Stay "Connected" if we had a successful request in the last 2 minutes
                // This prevents flickering status on temporary network hiccups or long-polling timeouts
                if self.connectionStatus == .connected {
                    let gracePeriod: TimeInterval = 120  // 2 minutes
                    if !self.isConnectionStale(threshold: gracePeriod) {
                        // Had successful request recently - stay connected
                        Log.debug("⚠️ Non-critical error, but staying Connected (last success was recent)", category: "ConnectionStatus")
                        return
                    } else {
                        // No successful request in 2 minutes - mark as connecting
                        self.connectionStatus = .connecting
                    }
                }
            }
            
            if oldStatus != self.connectionStatus {
                Log.info("🔴 Connection status changed: \(oldStatus.displayText) -> \(self.connectionStatus.displayText)", category: "ConnectionStatus")
                if let error = error {
                    Log.info("   Error: \(error)", category: "ConnectionStatus")
                }
            }
        }
    }

    /// Call this when starting to connect/check server
    func markConnecting() {
        DispatchQueue.main.async { [weak self] in
            if self?.connectionStatus != .connected {
                self?.connectionStatus = .connecting
            }
        }
    }

    // MARK: - gRPC Stream Integration

    /// Call when the gRPC MessageStream establishes a connection
    func markStreamConnected() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let old = self.connectionStatus
            self.lastSuccessfulRequest = Date()
            self.lastError = nil
            self.connectionStatus = .connected
            if old != .connected {
                Log.info("🟢 Stream connected → status: Connected", category: "ConnectionStatus")
            }
        }
    }

    /// Call when the gRPC MessageStream disconnects or errors
    func markStreamDisconnected(error: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastError = error
            if self.reachabilityManager.isReachable {
                if self.connectionStatus == .connected {
                    self.connectionStatus = .connecting
                    Log.info("🟡 Stream disconnected → status: Connecting", category: "ConnectionStatus")
                }
            } else {
                self.connectionStatus = .disconnected
            }
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
