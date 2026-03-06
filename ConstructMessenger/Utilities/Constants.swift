//
//  Constants.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import SwiftUI

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

// MARK: - Account Deletion Configuration
struct AccountDeletionConfig {
    static let challengeTTLSeconds: TimeInterval = 60
}

// MARK: - Avatar Styling
struct AvatarStyle {
    static let chatSize: CGFloat = 50
    static let settingsSize: CGFloat = 54
    static let bubbleSize: CGFloat = 60
    static let accountSize: CGFloat = 100

    /// iOS superellipse (squircle) shape — same proportions as iOS App Icons.
    static func squircle(_ size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
    }
}

// MARK: - Server Configuration
struct ServerConfig {
    // Primary server URL - API Gateway (routes to all services)
    static var defaultRestAPIURL: String {
        return "https://ams.konstruct.cc"
    }

    // Public invite host (must have .well-known)
    static let inviteHost: String = "konstruct.cc"
    
    // Single URL - API Gateway handles routing
    static var serverURLs: [String] {
        return [defaultRestAPIURL]
    }
}

// MARK: - Invite Configuration
struct InviteConfig {
    static let supportedVersions: Set<Int> = [1, 2]
    static let currentVersion: Int = 2
    static let ttlSeconds: TimeInterval = 300 // 5 minutes
    static let maxFutureSkewSeconds: TimeInterval = 300 // 5 minutes
    static let deviceIdLength = 32
    static let deviceIdRegex = "^[a-f0-9]{32}$"
    static let ephKeyLengthBytes = 32
    static let signatureLengthBytes = 64
    static let qrWarningThresholdSeconds: TimeInterval = 60
    static let qrCodePrefixScheme = "konstruct://add"
    static let qrCountdownTickSeconds: TimeInterval = 5
}



// MARK: - API Constants
struct APIConstants {
    // WebSocket Server URL (managed by .xcconfig)
    static var websocketURL: String {
        ServerConfig.defaultRestAPIURL
    }

    // Default server URL key for AppStorage and Keychain
    static let customServerURLKey = "customServerURL"

    // Getter for custom server URL (checks Keychain first, then UserDefaults for backward compatibility)
    static var customServerURL: String? {
        // Try Keychain first (persists across app reinstalls)
        if let keychainURL = KeychainManager.shared.loadCustomServerURL() {
            // Sync to UserDefaults for fast access
            if UserDefaults.standard.string(forKey: customServerURLKey) != keychainURL {
                UserDefaults.standard.set(keychainURL, forKey: customServerURLKey)
            }
            return keychainURL
        }
        
        // Fallback to UserDefaults (for backward compatibility)
        if let userDefaultsURL = UserDefaults.standard.string(forKey: customServerURLKey) {
            // Migrate to Keychain if not already there
            KeychainManager.shared.saveCustomServerURL(userDefaultsURL)
            return userDefaultsURL
        }
        
        return nil
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
    static let connectionTimeout: TimeInterval = 30.0  // URLSession timeout for regular requests
    static let messageAckTimeout: TimeInterval = 15.0  // Timeout for message ACK (increased for poor network)
    static let reconnectMaxDelay: TimeInterval = 30.0
    static let messageSendTimeout: TimeInterval = 20.0  // Timeout for stuck messages in sending state
    static let messageSendNetworkTimeout: TimeInterval = 60.0  // Network timeout for POST /api/v1/messages (slow networks)
    static let queueCheckInterval: TimeInterval = 5.0   // How often to check for stuck messages
    static let longPollingTimeout: TimeInterval = 65.0  // > server timeout (60 max)
    static let longPollingResourceTimeout: TimeInterval = 70.0  // Buffer for long polling resource timeout
    
    // Retry Configuration
    static let maxRetryAttempts: Int = 3  // Max retry attempts for transient failures
    static let retryBaseDelay: TimeInterval = 1.0  // Base delay for exponential backoff (1s, 2s, 4s)

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

// MARK: - Message Size Limits
struct MessageSizeLimits {
    // Text Message Limits
    // Note: These are for encrypted content, actual plaintext will be smaller due to encryption overhead
    static let maxTextMessageBytes: Int = 100 * 1024 * 1024  // 100 MB (encrypted)
    static let maxPlaintextMessageBytes: Int = 50 * 1024 * 1024  // 50 MB (plaintext, conservative estimate)

    // File Attachment Limits
    static let maxFileAttachmentBytes: Int64 = 500 * 1024 * 1024  // 500 MB

    // Specific file type limits (can be more restrictive)
    static let maxImageBytes: Int64 = 100 * 1024 * 1024  // 100 MB for images
    static let maxVideoBytes: Int64 = 500 * 1024 * 1024  // 500 MB for videos
    static let maxDocumentBytes: Int64 = 200 * 1024 * 1024  // 200 MB for documents
    static let maxAudioBytes: Int64 = 100 * 1024 * 1024  // 100 MB for audio

    // Total message size (text + all attachments)
    static let maxTotalMessageBytes: Int64 = 500 * 1024 * 1024  // 500 MB total

    // Supported file types
    static let supportedImageTypes: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp"]
    static let supportedVideoTypes: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
    static let supportedDocumentTypes: Set<String> = ["pdf", "doc", "docx", "txt", "rtf", "pages", "numbers", "key"]
    static let supportedAudioTypes: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "ogg"]

    // Helper functions
    static func maxSizeForFileType(_ fileExtension: String) -> Int64 {
        let ext = fileExtension.lowercased()

        if supportedImageTypes.contains(ext) {
            return maxImageBytes
        } else if supportedVideoTypes.contains(ext) {
            return maxVideoBytes
        } else if supportedDocumentTypes.contains(ext) {
            return maxDocumentBytes
        } else if supportedAudioTypes.contains(ext) {
            return maxAudioBytes
        } else {
            return maxFileAttachmentBytes
        }
    }

    static func isFileTypeSupported(_ fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return supportedImageTypes.contains(ext) ||
               supportedVideoTypes.contains(ext) ||
               supportedDocumentTypes.contains(ext) ||
               supportedAudioTypes.contains(ext)
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
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

// MARK: - Traffic Protection Configuration
struct TrafficProtectionConfig {
    // Battery Awareness
    static let batteryLevelThreshold: Float = 0.2  // 20% - disable below this
    static let defaultBatteryLevel: Float = 1.0    // Assume full battery if unknown

    // Timing Intervals (milliseconds) - Optimized for energy efficiency
    #if DEBUG
    // Debug: Shorter intervals for testing
    static let minIntervalMs: UInt64 = 30_000      // 30 seconds minimum
    static let maxIntervalMs: UInt64 = 300_000     // 5 minutes maximum
    static let schedulerCheckInterval: TimeInterval = 30.0  // Check every 30 seconds
    #else
    // Release: Longer intervals for battery life (max 30 dummies/hour instead of 120)
    static let minIntervalMs: UInt64 = 120_000     // 2 minutes minimum
    static let maxIntervalMs: UInt64 = 900_000     // 15 minutes maximum
    static let schedulerCheckInterval: TimeInterval = 120.0  // Check every 2 minutes
    #endif

    static let coalesceWindowMs: UInt64 = 15_000   // 15 seconds coalescing window (increased)

    // Message Configuration
    static let messageSize: UInt64 = 255           // Match PKCS7 padding block size
    static let coalesceWithRealMessages = true     // Enable smart coalescing

    // Jitter Configuration (milliseconds)
    static let highPriorityMaxJitterMs: UInt64 = 50    // User messages: 0-50ms
    static let lowPriorityMaxJitterMs: UInt64 = 100    // Other messages: 0-100ms
    static let batteryJitterReductionFactor: Float = 0.5  // 50% reduction at low battery

    // Send Smoothing
    static let minSendIntervalMs: UInt64 = 200  // Minimum spacing between outgoing messages
    static let lowBatterySendIntervalMultiplier: Double = 2.0  // Increase interval when battery is low
    static let sendJitterMinMs: UInt64 = 50
    static let sendJitterMaxMs: UInt64 = 500

    // Feature Flags
    #if DEBUG
    static let allowUserToggle = true              // Allow users to disable in debug
    #else
    static let allowUserToggle = false             // Always enabled in release
    #endif
}

// MARK: - Message Padding Configuration
struct MessagePaddingConfig {
    // Buckets are raw ciphertext sizes (after encryption, before Base64)
    static let buckets: [Int] = [1024, 4096, 16384]
    static let enabled: Bool = true
}

// MARK: - Chunked Delivery Configuration
struct ChunkedDeliveryConfig {
    static let magic: [UInt8] = [0x4B, 0x4E, 0x53, 0x54] // "KNST"
    static let version: UInt8 = 0x01
    static let flags: UInt8 = 0x00

    static let headerSize = 30
    static let maxPlaintextSize = 16 * 1024
    static let chunkPayloadSize = 3770
    static let maxChunks: UInt16 = 256
    static let reassemblyTimeout: TimeInterval = 60

    static let chunkSendJitterMinMs: UInt64 = 50
    static let chunkSendJitterMaxMs: UInt64 = 200
}

// MARK: - Long Polling Configuration
struct LongPollingConfig {
    // Add jitter after successful polls to reduce timing correlation
    // Reduced from 2-5s to 1-3s for faster response while maintaining privacy
    static let successJitterMinMs: UInt64 = 1000   // 1 second
    static let successJitterMaxMs: UInt64 = 3000   // 3 seconds

    // Polling behavior
    static let fullTimeoutSeconds: Int = 30
    static let minimalTimeoutSeconds: Int = 30
    static let minimalPostPollDelaySeconds: TimeInterval = 60
}

// MARK: - WebSocket Configuration
struct WebSocketConfig {
    // Connection Timeouts
    static let pingInterval: TimeInterval = 25.0          // Send ping every 25 seconds
    static let reconnectBaseDelay: TimeInterval = 2.0     // Base delay for exponential backoff
    static let reconnectMaxDelay: TimeInterval = 30.0     // Max reconnect delay

    // Background Fetch Timeouts
    static let backgroundFetchTimeout: TimeInterval = 15.0
    static let backgroundFetchRequestTimeout: TimeInterval = 15.0
    static let backgroundFetchResourceTimeout: TimeInterval = 20.0

    // Connection Delays
    static let authenticationDelay: TimeInterval = 0.5    // Delay before authenticating
    static let messageQueueFlushDelay: TimeInterval = 0.1 // Delay before flushing queue
}

// MARK: - UserDefaults Keys
enum UserDefaultsKey: String {
    // Traffic Protection
    case trafficProtectionEnabled = "trafficProtection_enabled"

    // ICE — traffic obfuscation (Intrusion Countermeasures Electronics)
    case iceEnabled = "ice_enabled"

    // Background Fetch
    case backgroundFetchEnabled = "backgroundFetch_enabled"
    case backgroundFetchIntervalMinutes = "backgroundFetch_intervalMinutes"

    // Session
    case sessionExpires = "session_expires"

    // Server Configuration
    case customServerURL = "customServerURL"

    // App Theme
    case appTheme = "appTheme"

    // Helper methods
    var key: String { rawValue }
}

// MARK: - Log Categories
enum LogCategory: String {
    case trafficProtection = "TrafficProtection"
    case webSocket = "WebSocket"
    case cryptoManager = "CryptoManager"
    case backgroundFetch = "BackgroundFetch"
    case deepLink = "DeepLink"
    case network = "Network"
    case auth = "Auth"
    case general = "General"

    var name: String { rawValue }
}

// MARK: - Debug Helpers
extension APIConstants {
    // Для тестирования можно временно переключить сервер
    static func useCustomServer(_ url: String) {
        // Save to both Keychain (persistent) and UserDefaults (fast access)
        KeychainManager.shared.saveCustomServerURL(url)
        UserDefaults.standard.set(url, forKey: customServerURLKey)
        NotificationCenter.default.post(name: .serverURLChanged, object: nil)
        print("⚠️ Using custom server: \(url)")
    }

    static func resetToDefault() {
        // Remove from both Keychain and UserDefaults
        KeychainManager.shared.deleteCustomServerURL()
        UserDefaults.standard.removeObject(forKey: customServerURLKey)
        NotificationCenter.default.post(name: .serverURLChanged, object: nil)
        print("✅ Reset to default server: \(websocketURL)")
    }
    
    // Save custom server URL (used by settings views)
    static func saveCustomServerURL(_ url: String?) {
        if let url = url, !url.isEmpty {
            KeychainManager.shared.saveCustomServerURL(url)
            UserDefaults.standard.set(url, forKey: customServerURLKey)
        } else {
            KeychainManager.shared.deleteCustomServerURL()
            UserDefaults.standard.removeObject(forKey: customServerURLKey)
        }
        NotificationCenter.default.post(name: .serverURLChanged, object: nil)
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let serverURLChanged = Notification.Name("serverURLChanged")
}
