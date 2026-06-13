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
    static let chatSize: CGFloat = 56
    static let settingsSize: CGFloat = 54
    static let bubbleSize: CGFloat = 60
    static let accountSize: CGFloat = 100

    /// Current avatar clip shape. Change here to update all avatars app-wide.
    /// Future: swap to HexagonShape() when the visual language is ready.
    static func avatarShape(_ size: CGFloat = 0) -> Circle {
        Circle()
    }

    /// Legacy alias — kept so existing call sites compile without changes.
    @available(*, deprecated, renamed: "avatarShape")
    static func squircle(_ size: CGFloat) -> Circle { avatarShape(size) }
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
    /// Versions the client can DECODE and accept (forward-compatible with V3).
    static let supportedVersions: Set<Int> = [1, 2, 3]

    /// Version used when GENERATING new invites.
    ///
    /// Currently set to 2 for server compatibility during the V3 rollout.
    /// The server must support V3 canonical string (`…|ts|un`) before this is bumped.
    /// Upgrade path: change this single constant to 3 once server is deployed.
    static let currentVersion: Int = 3
    static let ttlSeconds: TimeInterval = 300 // 5 minutes
    static let maxFutureSkewSeconds: TimeInterval = 300 // 5 minutes
    static let deviceIdLength = 32
    static let deviceIdRegex = "^[a-f0-9]{32}$"
    static let ephKeyLengthBytes = 32
    static let signatureLengthBytes = 64
    static let qrWarningThresholdSeconds: TimeInterval = 60
    static let qrCodePrefixScheme = "konstruct://add"
    static let qrCountdownTickSeconds: TimeInterval = 1
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

    // API Timeouts (forwarded — single source of truth is `NetworkTiming`)
    static let connectionTimeout: TimeInterval = NetworkTiming.HTTP.connectionTimeout
    static let messageAckTimeout: TimeInterval = NetworkTiming.Messaging.messageAckTimeout
    static let reconnectMaxDelay: TimeInterval = NetworkTiming.WebSocket.reconnectMaxDelay
    static let messageSendTimeout: TimeInterval = NetworkTiming.Messaging.messageSendTimeout
    static let messageSendNetworkTimeout: TimeInterval = NetworkTiming.HTTP.messageSendNetworkTimeout
    static let queueCheckInterval: TimeInterval = NetworkTiming.Messaging.queueCheckInterval
    static let longPollingTimeout: TimeInterval = NetworkTiming.LongPolling.timeout
    static let longPollingResourceTimeout: TimeInterval = NetworkTiming.LongPolling.resourceTimeout

    // gRPC routing failover ("happy eyeballs") (forwarded)
    static let grpcFastFallbackDirectTimeout: TimeInterval = NetworkTiming.GRPC.fastFallbackDirectTimeout
    static let streamOpenAcceptTimeout: TimeInterval = NetworkTiming.GRPC.streamOpenAcceptTimeout
    static let streamOpenAcceptPollInterval: TimeInterval = NetworkTiming.GRPC.streamOpenAcceptPollInterval
    
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
    static let minPasswordLength = 8

    // Regex patterns
    static let usernamePattern = "^[a-zA-Z0-9_]{3,30}$"
}

// MARK: - Message Size Limits
struct MessageSizeLimits {
    // Text Message Limits
    static let maxTextCharacters: Int = 4_096          // UI hard limit (matches Telegram; ≈4–8 KB UTF-8)
    static let maxTextMessageBytes: Int = 64 * 1024    // 64 KB encrypted wire limit
    static let maxPlaintextMessageBytes: Int = 16 * 1024  // 16 KB plaintext (4096 chars × ~4 bytes)

    // Caption Limits (attached to media/file messages)
    static let maxCaptionCharacters: Int = 1_024       // 1 K chars is plenty for a media caption

    // Profile field limits (must match server-side validation)
    static let minUsernameCharacters: Int = 3
    static let maxUsernameCharacters: Int = 20         // server: username.len() <= 20
    static let maxDisplayNameCharacters: Int = 50      // reasonable client-side cap

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

    // Parallel-run flag: when true, outgoing messages are routed through ConstructEngine
    // instead of (and not in addition to) the legacy OutboundMessagePipeline path.
    // iOS: always false — UDP 443 blocked by OS until MASQUE is implemented.
    // macOS Desktop: true — QUIC works, use engine as primary send path.
    #if os(iOS)
    static let useEngineForSend = false
    #else
    static let useEngineForSend = true
    #endif

    /// HTTP/3 (QUIC) for gRPC streams on the direct path.
    ///
    /// **Disabled 2026-05-29** after device validation surfaced a silent failure mode:
    /// bidi MessageStream over H3 sends `subscribe` successfully but the server's
    /// initial response headers never reach the client — `onAccepted` never fires,
    /// stream hangs until heartbeat-watchdog tears it down ~75s later. Unary RPCs
    /// over H3 work fine; only bidi streaming is broken.
    ///
    /// Likely cause: Traefik 3.x QUIC↔h2c bridge mishandles bidi streaming response
    /// frames OR the custom `HTTP3ClientTransport.swift` doesn't surface initial
    /// response headers to the gRPC layer for bidi calls (it does for unary).
    ///
    /// Re-enable only after both ends have been verified end-to-end with a bidi
    /// streaming test. The H3 code paths in `MessageStreamTransport.swift`,
    /// `GRPCStreamTransport.open`, and `GRPCChannelManager.acquireH3Channel`
    /// remain intact for that future work.
    ///
    /// See `wiki/decisions/h3-disabled-on-ios.md` for the full context.
    static let h3Enabled: Bool = false
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
    static let successJitterMinMs: UInt64 = NetworkTiming.LongPolling.successJitterMinMs
    static let successJitterMaxMs: UInt64 = NetworkTiming.LongPolling.successJitterMaxMs

    // Polling behavior
    static let fullTimeoutSeconds: Int = NetworkTiming.LongPolling.fullTimeoutSeconds
    static let minimalTimeoutSeconds: Int = NetworkTiming.LongPolling.minimalTimeoutSeconds
    static let minimalPostPollDelaySeconds: TimeInterval = NetworkTiming.LongPolling.minimalPostPollDelaySeconds
}

// MARK: - WebSocket Configuration
struct WebSocketConfig {
    // Connection Timeouts
    static let pingInterval: TimeInterval = NetworkTiming.WebSocket.pingInterval
    static let reconnectBaseDelay: TimeInterval = NetworkTiming.WebSocket.reconnectBaseDelay
    static let reconnectMaxDelay: TimeInterval = NetworkTiming.WebSocket.reconnectMaxDelay

    // Background Fetch Timeouts
    static let backgroundFetchTimeout: TimeInterval = NetworkTiming.WebSocket.backgroundFetchTimeout
    static let backgroundFetchRequestTimeout: TimeInterval = NetworkTiming.WebSocket.backgroundFetchRequestTimeout
    static let backgroundFetchResourceTimeout: TimeInterval = NetworkTiming.WebSocket.backgroundFetchResourceTimeout

    // Connection Delays
    static let authenticationDelay: TimeInterval = NetworkTiming.WebSocket.authenticationDelay
    static let messageQueueFlushDelay: TimeInterval = NetworkTiming.WebSocket.messageQueueFlushDelay
}

// MARK: - UserDefaults Keys
enum UserDefaultsKey: String {
    // Traffic Protection
    case trafficProtectionEnabled = "trafficProtection_enabled"

    // VEIL — traffic obfuscation (Intrusion Countermeasures Electronics)
    case veilEnabled = "veil_enabled"
    case veilMode = "veil_mode"

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

// MARK: - VEIL Relay Region

/// Maps a UTC timezone offset range to a preferred relay ordering.
/// Used by VeilProxyManager to geo-prefer the closest relay without IP lookup or GPS.
/// Fetched from `.well-known/construct-server` and cached in UserDefaults;
/// falls back to `VEILConfig.hardcodedRelayRegions` when server config is unavailable.
struct VEILRelayRegion: Codable {
    /// Minimum UTC offset in hours (inclusive).
    let tzOffsetMin: Int
    /// Maximum UTC offset in hours (inclusive).
    let tzOffsetMax: Int
    /// Relay addresses to place at the front of the candidate list for this timezone range.
    let preferredRelays: [String]

    enum CodingKeys: String, CodingKey {
        case tzOffsetMin = "tz_offset_min"
        case tzOffsetMax = "tz_offset_max"
        case preferredRelays = "preferred_relays"
    }
}

// MARK: - VEIL Bridge Configuration
struct VEILConfig {
    /// Hardcoded fallback bridge cert used when Keychain is empty (first launch before login).
    /// This is the server's public obfs4 identity — not a secret, safe to embed in binary.
    /// Update this when the production server rotates its VEIL identity keypair.
    static let hardcodedBridgeCert = "3J8A3lAtPb3R4+td9UVLuzggZeva+o8TDNVw4aHx8HWdvdYpS4gV6t8gmxbGMIQTB5eGJA"

    /// Primary VEIL endpoint: TLS 1.3 → obfs4 → gRPC (Amsterdam, via Traefik).
    /// Uses `ice.<grpcHost>:443` derived at runtime from GRPCChannelManager.currentHost.

    // ── Relay 1: Moscow (Yandex Cloud) — REMOVED ────────────────────────────────
    // IP 158.160.140.67 confirmed blocked by RU DPI: TCP RST on TLS ClientHello
    // on both port 443 and 9443. Kept as comments for reference when a new RU
    // relay is deployed with proper CDN fronting (Cloudflare or equivalent).
    //
    // static let mskRelayIP             = "158.160.140.67"
    // static let mskRelaySNI            = "storage.yandexcloud.net"
    // static let mskRelayPinnedSPKI     = "ce2bbfcac1fffab1f4f41ee540aee2dea92c523f7768264aeb87184bf8bfa723"
    // static let mskRelayBridgeCert     = "IZKOsDNS5gld2g1PH4Uo4Yna/ltepGKpzDQTbSJll9OqzMin6yZaNx4gFbiLTvuGbABpcA"
    // static let mskRelayAddress        = "\(mskRelayIP):443"
    // static let mskRelayObfs4Address   = "\(mskRelayIP):9443"
    // static let mskTURNAddress         = "turn:\(mskRelayIP):3478"
    // static let mskSTUNAddress         = "stun:\(mskRelayIP):3478"

    // ── Relay 2: Amsterdam co-located (ice.ams.konstruct.cc) ─────────────────
    /// construct-relay running on the same VPS as the main server.
    /// Upstream: ams.konstruct.cc:443 via internal Docker network.
    static let amsRelayAddress    = "ice.ams.konstruct.cc:443"
    static let amsRelaySNI        = "ice.ams.konstruct.cc"
    static let amsRelayPinnedSPKI = "510d465a5c4736548e3386570ede6ba24600c4c9a2e369d24dde1ad7915eeebd"
    /// Update when the relay container is recreated (new keypair in /data/relay.obfs4).
    static let amsRelayBridgeCert = "voFt3ilLSKx2xYuZsjxOnXtHTktUE4EaExIYRG+Bh89frHzI5QVrBNvT41zdS7Maiu6gPA"

    // ── SPB relay removed 2026-05-16 ─────────────────────────────────────────
    // 45.135.233.5:52143 (VKCS SPb, s3.vkcs.cloud SNI) — IP blocked by RU DPI (TCP RST at TLS handshake).
    // VPS deleted. Replaced by ruRelay below (2026-05-16).

    // ── Relay 3: RU relay (api.divany-kresla.uk) ─────────────────────────────
    /// 2026-06-11: VPS repurposed as the **veil-front relay** (honest-front HTTPS +
    /// session-bound ticket auth). It terminates veil-TLS with its own Let's Encrypt
    /// cert and re-wraps gRPC over TLS to ams.konstruct.cc:443 (--backend-tls).
    /// SPKI below is now that veil-front cert. obfs4/WebTunnel are no longer served
    /// here — veil-front wins the coordinator race via `ruRelayVeilFrontTicket`.
    static let ruRelayAddress    = "api.divany-kresla.uk:443"
    static let ruRelaySNI        = "api.divany-kresla.uk"
    static let ruRelayPinnedSPKI = "b2361c0448a33a10e6521300aa4de8d8fe402791dd4fd5b0fe10fbb09457570c"
    /// Stale obfs4 keypair cert — kept only so the obfs4 probe has a bridge line; it
    /// fails fast (relay no longer speaks obfs4) and veil-front wins the race.
    static let ruRelayBridgeCert = "zdfEJKLpy4nVo09zbd/5q3Yx02FyL7Tlr+5Aurww51IbYacIWIqbcTndB1UL+n2g68XBQw"
    // The veil-front ticket is per-user auth material — NOT hardcoded here. It is
    // imported out-of-band via a signed config blob (QR / konstruct://veil-config deep
    // link) into VeilTicketStore. See VeilTicketProvisioning.swift.

    /// Ed25519 public key used to verify `.well-known/construct-server` signature.
    /// This is the ONLY value hardcoded permanently — everything else is OTA-updatable.
    /// Generated by: scripts/generate-signing-key.sh in construct-landing repo.
    static let relayConfigSigningKey = "8a0ee71cd95f86a9f6877211accefaff6bb97f3051b3b2141f1c71690b9a2dcf"

    /// Per-relay obfs4 bridge certs, keyed by relay address (IP:port or host:port).
    /// Used by makeRelay() to override the AMS cert for relays with their own obfs4 keypair.
    static let hardcodedRelayCerts: [String: String] = [
        amsRelayAddress: amsRelayBridgeCert,
        ruRelayAddress:  ruRelayBridgeCert,
        // mskRelayAddress: mskRelayBridgeCert,  // MSK relay removed — IP blocked by RU DPI
    ]

    /// Hardcoded relay list used as a last resort when discovery is unavailable.
    /// Order matters: relays are probed concurrently but this sets tie-break priority.
    static let hardcodedRelayAddresses: [String] = [
        amsRelayAddress,
        ruRelayAddress,
        // mskRelayAddress,  // MSK relay removed — 158.160.140.67 blocked by RU DPI (TLS RST)
    ]

    /// TLS SNI overrides keyed by relay address string.
    /// Required for IP-based relays (IPs cannot be used as TLS SNI).
    /// Also used for domain-based relays that need explicit SPKI pinning.
    static let hardcodedRelaySNIs: [String: String] = [
        amsRelayAddress: amsRelaySNI,
        ruRelayAddress:  ruRelaySNI,
        // mskRelayAddress:      mskRelaySNI,    // MSK removed
        // mskRelayObfs4Address: mskRelaySNI,    // MSK removed
    ]

    /// SPKI pins keyed by relay address. Looked up by makeRelay() for any relay
    /// that appears in hardcodedRelaySNIs.
    static let hardcodedRelaySPKIs: [String: String] = [
        amsRelayAddress: amsRelayPinnedSPKI,
        ruRelayAddress:  ruRelayPinnedSPKI,
        // mskRelayAddress:      mskRelayPinnedSPKI,    // MSK removed
        // mskRelayObfs4Address: mskRelayPinnedSPKI,    // MSK removed
    ]

    /// UserDefaults key where the relay list fetched from the server is cached.
    static let cachedRelayListKey = "construct.ice_relays"

    /// UserDefaults key where the relay-region config fetched from the server is cached.
    /// Value is JSON-encoded array of `ICERelayRegion` (see VeilCertFetcher).
    static let cachedRelayRegionsKey = "construct.ice_relay_regions"

    /// WebTunnel (ICE v2) WebSocket resource paths, keyed by relay address.
    /// When present, makeRelay() activates WebTunnel-first transport for that relay.
    /// Override via `.well-known/construct-server` `ice.relays[].wt_path` without a new build.
    static let hardcodedRelayWTPaths: [String: String] = [
        amsRelayAddress: "/construct-ice",
        ruRelayAddress:  "/api/stream",
        // mskRelayAddress: "/construct-ice",   // MSK removed
    ]

    /// Companion obfs4-only ports for CDN-fronted relays.
    // MSK relay removed — 9443 also RST by DPI
    static let hardcodedRelayObfs4Companions: [String: String] = [:]

    /// Alternative TLS SNI values per relay address for WebTunnel domain-fronting rotation.
    /// When WebTunnel is blocked by SNI-based DPI, these are tried in order before obfs4 fallback.
    /// Override (and extend) via `.well-known/construct-server` `ice.relays[].alternative_snis`
    /// without a binary update.
    static let hardcodedRelayAlternativeSNIs: [String: [String]] = [:]

    /// Fallback relay-region rules used when the server config has not been fetched yet.
    /// Each rule maps a UTC offset range (hours, inclusive) to a preferred relay ordering.
    /// The first matching rule wins; unmatched → default ordering.
    ///
    /// AMS first for everyone — it's always reachable globally.
    /// SPb is secondary: useful for RU users blocked by TSPU, harmless for others (just a fallback).
    /// RU-specific routing (SPb primary) is handled by the server OTA config via IP geolocation,
    /// not by timezone heuristics — timezone is a poor proxy for DPI presence.
    /// Override via `.well-known/construct-server` `ice.relay_regions` without a new build.
    static let hardcodedRelayRegions: [VEILRelayRegion] = [
        VEILRelayRegion(tzOffsetMin: -12, tzOffsetMax: 12, preferredRelays: [amsRelayAddress]),
    ]
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
        Log.info("Using custom server: \(url)")
    }

    static func resetToDefault() {
        // Remove from both Keychain and UserDefaults
        KeychainManager.shared.deleteCustomServerURL()
        UserDefaults.standard.removeObject(forKey: customServerURLKey)
        NotificationCenter.default.post(name: .serverURLChanged, object: nil)
        Log.info("Reset to default server: \(websocketURL)")
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
    static let serverURLChanged   = Notification.Name("serverURLChanged")
    static let deleteChat         = Notification.Name("constructDeleteChat")
    /// Posted when a contact's identity key changes since the last verified bundle.
    /// userInfo: ["userId": String]
    static let contactKeyChanged  = Notification.Name("constructContactKeyChanged")
}
