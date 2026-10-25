//
//  EnergyMonitor.swift
//  Construct Messenger
//
//

import Foundation
#if os(iOS)
import UIKit
#endif
import Network
import Synchronization

/// Monitors device energy state and network conditions to optimize background fetch
/// Implements battery-aware execution to minimize energy impact
final class EnergyMonitor: @unchecked Sendable {

    // MARK: - Properties

    /// Network path monitor for checking connectivity
    private let pathMonitor = NWPathMonitor()

    /// Network monitoring queue
    private let monitorQueue = DispatchQueue(label: "com.construct.networkmonitor")

    /// Current network path. Written on `monitorQueue`, read from whichever thread asks, so
    /// every access goes through the lock.
    private struct PathState {
        var current: NWPath?
        var lastStatus: NWPath.Status?
    }
    private let pathState = Mutex(PathState())

    private var currentPath: NWPath? { pathState.withLock { $0.current } }

    // MARK: - Initialization

    init() {
        setupNetworkMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Network Monitoring

    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let changed = self.pathState.withLock { state in
                state.current = path
                // NWPathMonitor may call this repeatedly with the same status; avoid log spam.
                let changed = state.lastStatus != path.status
                if changed { state.lastStatus = path.status }
                return changed
            }
            if changed {
                Log.debug("Network status changed: \(path.status)", category: "EnergyMonitor")
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Energy Checks

    /// Determines if background fetch should proceed based on energy conditions
    /// Returns false if:
    /// - Battery is below 20% and not charging
    /// - Low Power Mode is enabled
    /// - No network connectivity
    func shouldPerformBackgroundFetch() async -> Bool {
        // Check network availability first (fastest check)
        guard isNetworkAvailable() else {
            Log.debug("Network not available, skipping fetch")
            return false
        }

        // Check Low Power Mode
        if isLowPowerModeEnabled() {
            Log.debug("Low Power Mode enabled, skipping fetch")
            return false
        }

        // Check battery level
        // UIDevice is main-actor API; the BGTask handler that asks is not on main.
        if await isBatteryLow(), await !isCharging() {
            Log.debug("Battery low and not charging, skipping fetch")
            return false
        }

        Log.debug("Energy conditions favorable for background fetch")
        return true
    }

    // MARK: - Battery Checks

    /// Check if battery level is below threshold (20%)
    @MainActor
    func isBatteryLow() -> Bool {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel < 0 { return false }
        return batteryLevel < 0.20
        #else
        return false  // macOS: assume battery is fine (usually plugged in)
        #endif
    }

    /// Check if device is currently charging
    @MainActor
    func isCharging() -> Bool {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryState = UIDevice.current.batteryState
        return batteryState == .charging || batteryState == .full
        #else
        return true  // macOS: assume plugged in
        #endif
    }

    /// Get current battery level as percentage (0-100)
    @MainActor
    func batteryLevelPercentage() -> Int {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel < 0 { return -1 }
        return Int(batteryLevel * 100)
        #else
        return 100  // macOS: assume full
        #endif
    }

    /// Check if Low Power Mode is enabled
    func isLowPowerModeEnabled() -> Bool {
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: - Network Checks

    /// Check if network is available
    func isNetworkAvailable() -> Bool {
        guard let path = currentPath else {
            return false
        }

        return path.status == .satisfied
    }

    /// Check if network is expensive (cellular data)
    func isNetworkExpensive() -> Bool {
        guard let path = currentPath else {
            return false
        }

        return path.isExpensive
    }

    /// Check if network is constrained (Low Data Mode)
    func isNetworkConstrained() -> Bool {
        guard let path = currentPath else {
            return false
        }

        return path.isConstrained
    }

    /// Get network type description
    func networkTypeDescription() -> String {
        guard let path = currentPath else {
            return "Unknown"
        }

        if path.usesInterfaceType(.wifi) {
            return "WiFi"
        } else if path.usesInterfaceType(.cellular) {
            return "Cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            return "Ethernet"
        } else {
            return "Other"
        }
    }

    // MARK: - Recommendations

    /// Get fetch strategy recommendation based on current conditions
    func getFetchStrategy() async -> FetchStrategy {
        if !isNetworkAvailable() {
            return .skip
        }

        if isLowPowerModeEnabled() {
            return .skip
        }

        if await isBatteryLow(), await !isCharging() {
            return .skip
        }

        if isNetworkExpensive() || isNetworkConstrained() {
            return .minimal // Fetch only critical messages
        }

        return .normal
    }

    /// Get energy impact description for UI
    func energyStatusDescription() async -> String {
        var components: [String] = []

        let battery = await batteryLevelPercentage()
        if battery >= 0 {
            components.append("Battery: \(battery)%")
        }

        if await isCharging() {
            components.append("Charging")
        }

        if isLowPowerModeEnabled() {
            components.append("Low Power Mode")
        }

        components.append("Network: \(networkTypeDescription())")

        if isNetworkExpensive() {
            components.append("Expensive")
        }

        if isNetworkConstrained() {
            components.append("Constrained")
        }

        return components.joined(separator: " • ")
    }
}

// MARK: - Fetch Strategy

enum FetchStrategy {
    case skip       // Don't fetch at all
    case minimal    // Fetch only critical data
    case normal     // Normal fetch operation

    var description: String {
        switch self {
        case .skip:
            return "Skipping fetch"
        case .minimal:
            return "Minimal fetch"
        case .normal:
            return "Normal fetch"
        }
    }
}
