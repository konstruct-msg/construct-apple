//
//  NetworkReachabilityManager.swift
//  Construct Messenger
//
//  Network reachability monitoring for offline/online detection
//

import Foundation
import Network
import os.log

/// Manages network reachability monitoring
@Observable
class NetworkReachabilityManager {
    static let shared = NetworkReachabilityManager()
    
    var isReachable = true
    var connectionType: ConnectionType = .unknown

    enum ConnectionType: Equatable {
        case wifi
        case cellular
        case ethernet
        case other
        case unavailable
        case unknown
    }

    private var monitor: NWPathMonitor?
    private var queue: DispatchQueue?
    /// Tracks the previous connection type to detect interface changes (e.g. VPN → WiFi).
    private var prevConnectionType: ConnectionType = .unknown
    
    private init() {
        // Always set default values first
        isReachable = true
        connectionType = .wifi
        
        // Start monitoring (will skip if in preview)
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    func startMonitoring() {
        // Skip in preview mode
        if PreviewDetector.isRunningInPreview {
            Log.info("🌐 NetworkReachabilityManager: Skipping monitoring in preview mode", category: "NetworkReachability")
            return
        }
        
        // Check if Network framework is available (should always be on iOS, but safety check)
        #if !os(iOS)
        Log.info("🌐 Network framework may not be available on this platform", category: "NetworkReachability")
        #endif
        
        // Create monitor and queue only when needed (not in preview)
        // Wrap in do-catch for safety, though NWPathMonitor() shouldn't throw
        let newMonitor = NWPathMonitor()
        let newQueue = DispatchQueue(label: "com.construct.network.reachability")
        
        newMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                let wasReachable = self.isReachable
                self.isReachable = path.status == .satisfied
                
                // Determine connection type
                if path.status == .satisfied {
                    if path.usesInterfaceType(.wifi) {
                        self.connectionType = .wifi
                    } else if path.usesInterfaceType(.cellular) {
                        self.connectionType = .cellular
                    } else if path.usesInterfaceType(.wiredEthernet) {
                        self.connectionType = .ethernet
                    } else {
                        self.connectionType = .other
                    }
                } else {
                    self.connectionType = .unavailable
                }
                
                // Notify subscribers if reachability changed OR if the network interface
                // changed while still reachable (e.g. VPN off → direct WiFi).
                // In both cases existing TCP connections are dead and must be reopened.
                let interfaceSwitched = self.isReachable && self.connectionType != self.prevConnectionType && self.prevConnectionType != .unknown
                self.prevConnectionType = self.connectionType
                if wasReachable != self.isReachable || interfaceSwitched {
                    Log.info("🌐 Network reachability changed: \(self.isReachable ? "ONLINE" : "OFFLINE") (\(self.connectionType))", category: "NetworkReachability")

                    // Post notification for other components
                    let notification = Notification(
                        name: .networkReachabilityChanged,
                        object: nil,
                        userInfo: ["isReachable": self.isReachable, "connectionType": self.connectionType]
                    )
                    NotificationCenter.default.post(notification)

                    // Also post a path-changed notification so subscribers can restart ICE /
                    // cancel stale TCP connections even when reachability stays .satisfied.
                    if interfaceSwitched {
                        NotificationCenter.default.post(
                            name: .networkPathChanged,
                            object: nil,
                            userInfo: ["connectionType": self.connectionType]
                        )
                    }
                }
            }
        }
        
        newMonitor.start(queue: newQueue)
        self.monitor = newMonitor
        self.queue = newQueue
        Log.info("🌐 Network reachability monitoring started", category: "NetworkReachability")
    }
    
    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
        queue = nil
        Log.info("🌐 Network reachability monitoring stopped", category: "NetworkReachability")
    }
    
    /// Check if network is currently reachable
    var isNetworkAvailable: Bool {
        return isReachable
    }
    
    /// Check if connection is via cellular (may want to warn user about data usage)
    var isCellularConnection: Bool {
        return connectionType == .cellular
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let networkReachabilityChanged = Notification.Name("networkReachabilityChanged")
    /// Fired when network interface switches (e.g. VPN off → WiFi) while remaining reachable.
    /// Stale TCP connections bound to the old interface must be closed and reopened.
    static let networkPathChanged = Notification.Name("networkPathChanged")
}
