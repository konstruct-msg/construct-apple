//
//  Constants.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation

// MARK: - Build Configuration
enum BuildConfiguration {
    case debug
    case release

    static var current: BuildConfiguration {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }
}

// MARK: - Server Configuration
struct ServerConfig {
    static var defaultWebsocketURL: String {
        do {
            var value: String = try ConfigurationManager.value(for: "APIBaseURL")
            // убрать кавычки и пробелы
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            print("🔍 normalized APIBaseURL =", value)
            guard !value.isEmpty else { throw ConfigurationManager.Error.invalidValue }
            return value
        } catch {
            print("⚠️ Using fallback WebSocket URL due to config error:", error)
            return "wss://api.konstruct.cc"
        }
    }
}



// MARK: - API Constants
struct APIConstants {
    // WebSocket Server URL (managed by .xcconfig)
    static var websocketURL: String {
        ServerConfig.defaultWebsocketURL
    }

    // Default server URL key for AppStorage
    static let customServerURLKey = "customServerURL"

    // Fallback getter for non-SwiftUI contexts
    static var customServerURL: String? {
        UserDefaults.standard.string(forKey: customServerURLKey)
    }

    static var activeServerURL: String {
        customServerURL ?? websocketURL
    }

    // Keychain Keys
    static let sessionTokenKey = "session_token"
    static let privateKeyKey = "private_key"
    static let userIdKey = "user_id"
    static let lastUsernameKey = "last_username"

    // API Timeouts
    static let connectionTimeout: TimeInterval = 10.0
    static let messageAckTimeout: TimeInterval = 15.0  // Timeout for message ACK (increased for poor network)
    static let reconnectMaxDelay: TimeInterval = 30.0
    static let messageSendTimeout: TimeInterval = 20.0  // Timeout for stuck messages in sending state
    static let queueCheckInterval: TimeInterval = 5.0   // How often to check for stuck messages

    // Server Info (для отображения в UI)
    static var serverInfo: String {
        let config = BuildConfiguration.current == .debug ? "Debug" : "Release"
        let url = activeServerURL
        return "(\(config)) \(url)"
    }
}

// MARK: - Validation Rules
struct ValidationRules {
    static let minUsernameLength = 3
    static let maxUsernameLength = 30
    static let minPasswordLength = 6

    // Regex patterns
    static let usernamePattern = "^[a-zA-Z0-9_]{3,30}$"
}

// MARK: - App Constants
struct AppConstants {
    static let appName = "Konstruct"
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    static let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    // Debug Settings
    static let enableDebugLogging = BuildConfiguration.current == .debug
    static let enableVerboseWebSocketLogging = false // Включить для детальных логов
}

// MARK: - Feature Flags
struct FeatureFlags {
    // Можно использовать для A/B тестирования или постепенного rollout
    static let enableMessageRetry = true
    static let enableAutoReconnect = true
    static let enableOfflineQueue = true
    static let enablePushNotifications = false // Пока не реализовано
    static let maxMessageRetryAttempts = 3
}

// MARK: - Debug Helpers
extension APIConstants {
    // Для тестирования можно временно переключить сервер
    static func useCustomServer(_ url: String) {
        UserDefaults.standard.set(url, forKey: customServerURLKey)
        NotificationCenter.default.post(name: .serverURLChanged, object: nil)
        print("⚠️ Using custom server: \(url)")
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: customServerURLKey)
        NotificationCenter.default.post(name: .serverURLChanged, object: nil)
        print("✅ Reset to default server: \(websocketURL)")
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let serverURLChanged = Notification.Name("serverURLChanged")
}
