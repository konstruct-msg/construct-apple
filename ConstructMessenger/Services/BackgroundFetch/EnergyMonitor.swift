//
//  EnergyMonitor.swift
//  Construct Messenger
//
//

import Foundation
import UIKit
import Network

/// Monitors device energy state and network conditions to optimize background fetch
/// Implements battery-aware execution to minimize energy impact
class EnergyMonitor {

    // MARK: - Properties

    /// Network path monitor for checking connectivity
    private let pathMonitor = NWPathMonitor()

    /// Network monitoring queue
    private let monitorQueue = DispatchQueue(label: "com.construct.networkmonitor")

    /// Current network path
    private var currentPath: NWPath?

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
            self?.currentPath = path
            Log.error("Network status changed: \(path.status)")
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Energy Checks

    /// Determines if background fetch should proceed based on energy conditions
    /// Returns false if:
    /// - Battery is below 20% and not charging
    /// - Low Power Mode is enabled
    /// - No network connectivity
    func shouldPerformBackgroundFetch() -> Bool {
        // Check network availability first (fastest check)
        guard isNetworkAvailable() else {
            Log.debug("❌ Network not available, skipping fetch")
            return false
        }

        // Check Low Power Mode
        if isLowPowerModeEnabled() {
            Log.debug("❌ Low Power Mode enabled, skipping fetch")
            return false
        }

        // Check battery level
        if isBatteryLow() && !isCharging() {
            Log.debug("❌ Battery low and not charging, skipping fetch")
            return false
        }

        Log.debug("✅ Energy conditions favorable for background fetch")
        return true
    }

    // MARK: - Battery Checks

    /// Check if battery level is below threshold (20%)
    func isBatteryLow() -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel

        // batteryLevel returns -1.0 if battery state is unknown
        if batteryLevel < 0 {
            // If we can't determine battery level, assume it's safe to proceed
            return false
        }

        return batteryLevel < 0.20 // Less than 20%
    }

    /// Check if device is currently charging
    func isCharging() -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryState = UIDevice.current.batteryState

        return batteryState == .charging || batteryState == .full
    }

    /// Get current battery level as percentage (0-100)
    func batteryLevelPercentage() -> Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel

        if batteryLevel < 0 {
            return -1 // Unknown
        }

        return Int(batteryLevel * 100)
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
    func getFetchStrategy() -> FetchStrategy {
        if !isNetworkAvailable() {
            return .skip
        }

        if isLowPowerModeEnabled() {
            return .skip
        }

        if isBatteryLow() && !isCharging() {
            return .skip
        }

        if isNetworkExpensive() || isNetworkConstrained() {
            return .minimal // Fetch only critical messages
        }

        return .normal
    }

    /// Get energy impact description for UI
    func energyStatusDescription() -> String {
        var components: [String] = []

        let battery = batteryLevelPercentage()
        if battery >= 0 {
            components.append("Battery: \(battery)%")
        }

        if isCharging() {
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
