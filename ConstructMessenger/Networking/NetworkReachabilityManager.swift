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

    /// Describes the nature of a network path change so consumers can choose
    /// how aggressively to reset connection state.
    enum NetworkChangeKind {
        /// The high-level interface type switched (e.g. WiFi → cellular).
        /// All relay blacklists should be cleared; relays reachable on one
        /// interface may be unreachable on the other and vice-versa.
        case newInterface
        /// The topology changed without switching interface type (VPN toggle,
        /// IP rotation, interface added/removed). Relay DPI-block status is
        /// likely unchanged; keep blacklist, skip expensive relay rediscovery.
        case pathTopology
    }

    private var monitor: NWPathMonitor?
    private var queue: DispatchQueue?
    /// Tracks the previous connection type to detect interface changes (e.g. WiFi → cellular).
    private var prevConnectionType: ConnectionType = .unknown
    /// Fingerprint of the previous NWPath interface set (sorted interface names, e.g. "en0,utun3").
    /// Detects VPN on/off, interface additions/removals that don't change the high-level
    /// ConnectionType but still invalidate existing TCP connections.
    private var prevPathFingerprint: String = ""
    
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
            Log.info("NetworkReachabilityManager: Skipping monitoring in preview mode", category: "NetworkReachability")
            return
        }
        
        // Check if Network framework is available (should always be on iOS, but safety check)
        #if !os(iOS)
        Log.info("Network framework may not be available on this platform", category: "NetworkReachability")
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
                // changed while still reachable (e.g. VPN on/off, cellular ↔ WiFi).
                // In both cases existing TCP connections are dead and must be reopened.
                let interfaceTypeSwitched = self.isReachable && self.connectionType != self.prevConnectionType && self.prevConnectionType != .unknown

                // Detect VPN and other path changes that don't alter the high-level
                // ConnectionType. VPN creates a utun interface; enabling/disabling it
                // changes the available interface set without changing wifi/cellular.
                let fingerprint = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
                let pathTopologyChanged = self.isReachable
                    && !self.prevPathFingerprint.isEmpty
                    && fingerprint != self.prevPathFingerprint
                self.prevPathFingerprint = fingerprint

                let interfaceSwitched = interfaceTypeSwitched || pathTopologyChanged
                self.prevConnectionType = self.connectionType
                if wasReachable != self.isReachable || interfaceSwitched {
                    Log.info("Network reachability changed: \(self.isReachable ? "ONLINE" : "OFFLINE") (\(self.connectionType))", category: "NetworkReachability")

                    // Post notification for other components
                    let notification = Notification(
                        name: .networkReachabilityChanged,
                        object: nil,
                        userInfo: ["isReachable": self.isReachable, "connectionType": self.connectionType]
                    )
                    NotificationCenter.default.post(notification)

                    // Also post a path-changed notification so subscribers can restart VEIL /
                    // cancel stale TCP connections even when reachability stays .satisfied.
                    if interfaceSwitched {
                        let changeKind: NetworkChangeKind = interfaceTypeSwitched ? .newInterface : .pathTopology
                        NotificationCenter.default.post(
                            name: .networkPathChanged,
                            object: nil,
                            userInfo: ["connectionType": self.connectionType, "changeKind": changeKind]
                        )
                    }
                }
            }
        }
        
        newMonitor.start(queue: newQueue)
        self.monitor = newMonitor
        self.queue = newQueue
        Log.info("Network reachability monitoring started", category: "NetworkReachability")
    }
    
    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
        queue = nil
        Log.info("Network reachability monitoring stopped", category: "NetworkReachability")
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
    /// Fired when network interface switches (e.g. VPN on/off, cellular ↔ WiFi) while remaining reachable.
    /// Stale TCP connections bound to the old interface must be closed and reopened.
    static let networkPathChanged = Notification.Name("networkPathChanged")
    /// Fired when VEIL proxy starts or stops. Payload: `userInfo["isRunning"]` = Bool.
    /// Used by ConnectionStatusManager to proactively degrade status when proxy dies
    /// before the stream heartbeat watchdog detects the failure.
    static let veilProxyStateChanged = Notification.Name("veilProxyStateChanged")
}
