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

/// Whether an offline fetch may proceed, given the two places a session token can live.
///
/// `GRPCAuthCache` is empty until `AuthSessionManager.loadSessionToken()` runs. Background
/// fetch and `fetchMissedMessages` used to read only the cache, so a silent push or stream
/// reconnect that beat restore logged ERROR "No session token available" / `unavailable`
/// four times in a row (2026-08-19) — the token was in Keychain the whole time.
enum BackgroundFetchAuthGate {
    enum Decision: Equatable {
        /// Cache already has a token.
        case proceed
        /// Cache is empty, Keychain is not — hydrate then proceed.
        case hydrateThenProceed
        /// Neither store has a token. Skip; this is not a network failure.
        case skipNotAuthenticated
    }

    static func decision(cacheHasToken: Bool, keychainHasToken: Bool) -> Decision {
        if cacheHasToken { return .proceed }
        if keychainHasToken { return .hydrateThenProceed }
        return .skipNotAuthenticated
    }
}

enum SessionTokenHydrator {
    /// Fill `GRPCAuthCache` from Keychain when the cache is empty. Returns whether a
    /// token is available afterwards. Must run on the main actor because it touches
    /// `AuthSessionManager`.
    @MainActor
    static func ensureCached() -> Bool {
        switch BackgroundFetchAuthGate.decision(
            cacheHasToken: GRPCAuthCache.shared.snapshot.token != nil,
            keychainHasToken: KeychainManager.shared.loadSessionToken() != nil
        ) {
        case .proceed:
            return true
        case .hydrateThenProceed:
            AuthSessionManager.shared.loadSessionToken()
            return GRPCAuthCache.shared.snapshot.token != nil
        case .skipNotAuthenticated:
            return false
        }
    }
}
