//
//  BackgroundFetchConfig.swift
//  Construct Messenger
//
//  Created by Auto on 03.01.2026.
//

import Foundation

/// Configuration for background fetch settings
struct BackgroundFetchConfig {
    // MARK: - Default Values
    static let defaultIntervalMinutes: Int = 15
    static let minIntervalMinutes: Int = 5
    static let maxIntervalMinutes: Int = 60

    // MARK: - Properties

    /// Whether background fetch is enabled
    static var isEnabled: Bool {
        get {
            // Use the camelCase key that BackgroundFetchSettingsView writes via @AppStorage
            UserDefaults.standard.bool(forKey: "backgroundFetchEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "backgroundFetchEnabled")
            // Auto-disable if Low Power Mode is enabled
            if newValue && ProcessInfo.processInfo.isLowPowerModeEnabled {
                UserDefaults.standard.set(false, forKey: "backgroundFetchEnabled")
            }
        }
    }

    /// Background fetch interval in minutes
    static var intervalMinutes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: UserDefaultsKey.backgroundFetchIntervalMinutes.key)
            // Return default if not set or invalid
            if value < minIntervalMinutes || value > maxIntervalMinutes {
                return defaultIntervalMinutes
            }
            return value
        }
        set {
            // Clamp value to valid range
            let clampedValue = max(minIntervalMinutes, min(maxIntervalMinutes, newValue))
            UserDefaults.standard.set(clampedValue, forKey: UserDefaultsKey.backgroundFetchIntervalMinutes.key)
        }
    }
    
    /// Background fetch interval as TimeInterval (seconds)
    static var interval: TimeInterval {
        return TimeInterval(intervalMinutes * 60)
    }
    
    /// Check if background fetch should be enabled (respects Low Power Mode)
    static var shouldBeEnabled: Bool {
        guard isEnabled else { return false }
        
        // Auto-disable if Low Power Mode is enabled
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            if isEnabled {
                // Auto-disable and save
                UserDefaults.standard.set(false, forKey: "backgroundFetchEnabled")
            }
            return false
        }

        return true
    }

    // MARK: - Initialization

    /// Initialize with default values if not set
    static func initializeDefaults() {
        if UserDefaults.standard.object(forKey: UserDefaultsKey.backgroundFetchIntervalMinutes.key) == nil {
            intervalMinutes = defaultIntervalMinutes
        }
    }
    
    // MARK: - Helpers
    
    /// Format interval as readable string
    static func formatInterval(_ minutes: Int) -> String {
        if minutes < 60 {
            let format = NSLocalizedString("background_fetch_interval_minutes", comment: "")
            return String(format: format, minutes)
        } else {
            let hours = minutes / 60
            let format = NSLocalizedString("background_fetch_interval_hours", comment: "")
            return String(format: format, hours)
        }
    }
}
