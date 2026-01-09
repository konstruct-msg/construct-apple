//
//  NetworkReachabilityManager.swift
//  Construct Messenger
//
//  Network reachability monitoring for offline/online detection
//

import Foundation
import Network
import Combine
import os.log

/// Manages network reachability monitoring
class NetworkReachabilityManager: ObservableObject {
    static let shared = NetworkReachabilityManager()
    
    @Published var isReachable = true
    @Published var connectionType: ConnectionType = .unknown
    
    enum ConnectionType {
        case wifi
        case cellular
        case ethernet
        case other
        case unavailable
        case unknown
    }
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkReachability")
    private var cancellables = Set<AnyCancellable>()
    
    // Publishers for other components
    let reachabilityPublisher = PassthroughSubject<Bool, Never>()
    let connectionTypePublisher = PassthroughSubject<ConnectionType, Never>()
    
    private init() {
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
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
                
                // Notify subscribers if reachability changed
                if wasReachable != self.isReachable {
                    Log.info("🌐 Network reachability changed: \(self.isReachable ? "ONLINE" : "OFFLINE")", category: "NetworkReachability")
                    self.reachabilityPublisher.send(self.isReachable)
                    self.connectionTypePublisher.send(self.connectionType)
                    
                    // Post notification for other components
                    NotificationCenter.default.post(
                        name: .networkReachabilityChanged,
                        object: nil,
                        userInfo: ["isReachable": self.isReachable, "connectionType": self.connectionType]
                    )
                }
            }
        }
        
        monitor.start(queue: queue)
        Log.info("🌐 Network reachability monitoring started", category: "NetworkReachability")
    }
    
    func stopMonitoring() {
        monitor.cancel()
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
}
