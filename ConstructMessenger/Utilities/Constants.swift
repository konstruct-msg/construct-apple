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
    /// Versions the client can DECODE and accept.
    /// v4 drops dead `ephKey` (F2); v1–v3 remain for dual-read within TTL.
    static let supportedVersions: Set<Int> = [1, 2, 3, 4]

    /// Version used when GENERATING new invites.
    /// v4: no ephKey in canonical string / wire; server crypto-agility must accept v4.
    static let currentVersion: Int = 4
    /// How long a signed invite stays redeemable.
    ///
    /// **Must equal `INVITE_TTL_SECONDS` in construct-server**
    /// (`crates/crypto-agility/src/invites.rs`). The server checks expiry first,
    /// so raising this alone changes nothing except which side reports the
    /// failure, and `used_invites.expires_at` — the row that makes an invite
    /// one-time — is derived from the server's copy. Three carriers, one meaning,
    /// nothing in either build that can enforce the agreement; the only guard is
    /// `testInviteTTLMatchesServerConstant` plus this sentence.
    ///
    /// 2026-08-13: 300 → 43200 (12h). Five minutes worked for a QR held between
    /// two phones and could not work for a link sent through another messenger —
    /// it expired in the clipboard, and until this session the redeem side failed
    /// silently, so it read as "links are broken". One-time use and the TOFU
    /// `deviceId` pin carry what the short window was standing in for.
    static let ttlSeconds: TimeInterval = 43_200 // 12 hours

    /// Tolerance for a sender whose clock runs fast. Unrelated to `ttlSeconds`.
    /// NOTE: the server is stricter — `InviteToken::is_future` allows 60s. A sender
    /// 90s ahead is accepted here and rejected there; the server's answer is the
    /// one that decides, so this number is the more forgiving of the two, not the
    /// effective one.
    static let maxFutureSkewSeconds: TimeInterval = 300 // 5 minutes
    static let deviceIdLength = 32
    static let deviceIdRegex = "^[a-f0-9]{32}$"
    static let ephKeyLengthBytes = 32
    static let signatureLengthBytes = 64
    static let qrCodePrefixScheme = "konstruct://add"
    static let qrCountdownTickSeconds: TimeInterval = 1
    /// While the invite QR is on-screen, mint a fresh jti this often.
    ///
    /// Removed earlier on 2026-08-13 and restored the same day. The removal reasoned that at
    /// a 12-hour TTL each rotation mints another long-lived capability — true, and not the
    /// point. A screenshot captures ONE code whether or not the screen rotates, and ten
    /// capabilities naming the same identity are one exposure repeated, not ten. Rotation
    /// was never screenshot defence; it is what lets three people at a table scan in
    /// sequence and all three succeed, because an invite is burned by the first redeemer.
    /// [[decisions/invite-two-modes-deferred]] lists it as load-bearing for personal mode,
    /// which is the sentence that should have been read before deleting it.
    static let qrRotateIntervalSeconds: TimeInterval = 30
    /// How long the post-redeem safety toast stays visible (with Block action).
    static let postRedeemSafetyToastSeconds: TimeInterval = 8

    /// Localized duration of `ttlSeconds` for UI copy ("12 h" / "12 ч").
    ///
    /// Derived, never typed. A screen that says "valid 12 hours" beside a constant
    /// somebody later sets to 6 is the same defect as a comment describing code that
    /// changed underneath it — and unlike a comment, users act on this one.
    static var ttlDescription: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: ttlSeconds) ?? ""
    }

    /// Invite protocol versions that still carry a (unused) ephemeral X25519 pub.
    static func carriesEphKey(version: Int) -> Bool { version <= 3 }
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

    /// True for local Debug and Beta archives (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`
    /// includes `DEBUG`) and future `INTERNAL_TOOLS` TestFlight. False for App Store Release.
    static var isNonProductionBuild: Bool {
        #if DEBUG || INTERNAL_TOOLS
        true
        #else
        false
        #endif
    }

    /// e.g. `v0.17.0 (537)` or `v0.17.0 (537) BETA` on non-production builds.
    static var versionDisplayString: String {
        let base = "v\(appVersion) (\(buildNumber))"
        guard isNonProductionBuild else { return base }
        let beta = NSLocalizedString("build_channel_beta", comment: "Non-production build channel label")
        return "\(base) \(beta.uppercased())"
    }
}

// MARK: - Feature Flags
struct FeatureFlags {
    // Можно использовать для A/B тестирования или постепенного rollout
    static let enableMessageRetry = true
    static let enableAutoReconnect = true
    static let enableOfflineQueue = true
    static let enablePushNotifications = false // Пока не реализовано
    static let maxMessageRetryAttempts = 3

    /// Stealth-sealed-sender-v2 Phase 2: route sealed sends over the new unauthenticated
    /// `SendSealedMessage` RPC / separate gRPC channel instead of the legacy
    /// sealed-over-`SendMessage` path. **Default off** — flip only once the server RPC
    /// is deployed fleet-wide and this path has been validated (see
    /// construct-docs/decisions/stealth-sealed-sender-v2-always-on.md Phase 2).
    static let sealedSenderUnauthenticatedTransport = false

    // (stealthPerMessageDefault removed 2026-07-15: per-message is the only token model
    // now — the per-stream scope and its SecurityView picker are gone. A token rides
    // every sealed send; the server issuance cap (`TOKEN_ISSUANCE_MAX_PER_HOUR`) is the
    // effective sealed-send rate limit. decisions/sealed-sender-anti-abuse-economics.md.)

    // For Desktop we now use the direct iOS path (CryptoManager + gRPC-Swift) per Strategy B.
    // Engine send path is disabled for Desktop (engine paused for this surface).
    static let useEngineForSend = false

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

    /// Experimental QUIC/HTTP-3 via the dedicated `construct-transport` Rust stack
    /// (`QuicClientTransport`), routed through a native quinn+h3 gateway that bypasses
    /// the Traefik QUIC↔h2c bridge that broke the old native Swift H3 path.
    ///
    /// **Default `true` (auto-on).** This is NOT the dormant Swift H3 stack (`h3Enabled`) —
    /// it is the construct-transport QUIC path. When on, eligible RPCs use the engine QUIC
    /// channel with a fast hard fallback to H2 at the router (handshake 3s / idle 10s; see
    /// fast-fallback in construct-transport `tls.rs`). Auto-on is safe now that fallback is
    /// fast: on networks where QUIC is blocked/throttled it drops to H2/VEIL in seconds, and
    /// on networks where it works it's a win. The visible toggle is now a **kill-switch**
    /// (will move to `#if DEBUG` once we're confident — UI polish step).
    ///
    /// See `decisions/quic-moderate-dpi-udp-obfuscation.md`.
    ///
    /// **Release: always `true` (forced).** QUIC is a production transport, on for everyone with a
    /// fast hard fallback to H2 — there is no user kill-switch in release, and a stale stored value
    /// from an older build can never disable it. **DEBUG:** `UserDefaults`-backed (default `true`),
    /// so the DEBUG-only toggle in `NetworkSettingsView` can force it on/off for testing. Read fresh
    /// on every stream open, so toggling + a stream reconnect switches transport live (DEBUG only).
    /// `INTERNAL_TOOLS` is an opt-in compilation condition for internal TestFlight builds (which
    /// are Release config but need the QUIC kill-switch visible). Define it in the app target's
    /// Release Active Compilation Conditions for the internal round; remove it for the external
    /// round so QUIC is force-on with no toggle.
    static let engineQuicExperimentalKey = "ff.engineQuicExperimental"
    static var engineQuicExperimental: Bool {
        get {
//            #if DEBUG
            UserDefaults.standard.object(forKey: engineQuicExperimentalKey) as? Bool ?? true
//            #else
            //true  // forced on in external release — no kill-switch, stale stored value ignored
//            #endif
        }
        set {
//            #if DEBUG
            UserDefaults.standard.set(newValue, forKey: engineQuicExperimentalKey)
//            #endif
        }
    }

    /// **Default `false` (plain QUIC).** Salamander-obfuscate the engine-QUIC datagrams.
    /// Decided 2026-06-24 (see `decisions/quic-plain-vs-obfuscated.md`): QUIC is shipped as a
    /// plain transport — a competitive feature that works well on uncensored networks. On the
    /// blocked networks we care about the throttling is volumetric (sustained-UDP), which
    /// Salamander does NOT defeat (it only resists fingerprint-based DPI); and a bundled static
    /// PSK is weak against a targeted adversary anyway. So obfuscation is off by default and its
    /// only justification (Phase B in-band PSK rotation) is dropped. The Salamander obf path
    /// (`QuicObfPskStore`, `QuicGatewayConfig.bundledObfPsk`, Rust `connect_obfuscated`) stays
    /// as a dormant DEBUG-only option for experimentation; the production gateway runs plain.
    ///
    /// **Release: always `false` (forced).** Production ships plain QUIC; obfuscation never runs in
    /// release regardless of any stored value (the gateway is plain — obf datagrams would just be
    /// dropped). **DEBUG:** `UserDefaults`-backed (default `false`) so the DEBUG-only toggle can
    /// exercise the dormant Salamander path against a debug obf gateway.
    static let engineQuicObfuscatedKey = "ff.engineQuicObfuscated"
    static var engineQuicObfuscated: Bool {
        get {
            #if DEBUG
            UserDefaults.standard.object(forKey: engineQuicObfuscatedKey) as? Bool ?? false
            #else
            false  // forced off in release — production gateway is plain
            #endif
        }
        set {
            #if DEBUG
            UserDefaults.standard.set(newValue, forKey: engineQuicObfuscatedKey)
            #endif
        }
    }

    // `typedSessionControl` and `binarySessionControlPayload` were removed on 2026-08-03 with the
    // magic-string parser they gated (phases S2/S3, `decisions/binary-control-message-format.md`).
    //
    // Both had become one-way switches. ping/ready now carry their type in KNST byte 5 and go out
    // with `content_type` UNSPECIFIED whatever `typedSessionControl` said; and with the
    // consumer-side string parser gone, setting `binarySessionControlPayload = false` would have
    // produced handshakes no peer could read. A flag that can only break things is not an escape
    // hatch. There is no old population to fall back for — the app has never shipped.

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
    // Header byte 5 was `flags` — written 0x00 and never read. It now carries the content type
    // (values 0–26), inside the ciphertext where the server cannot read it. The version stays
    // 0x01: no reader ever interpreted byte 5, so nothing can be confused by it.

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

// MARK: - VEIL Seed Front (EntryDirectory Source 2)

/// One bundled seed front. The in-binary pin is the strongest trust anchor there is —
/// a seed is trusted because it shipped inside the signed app, needing no manifest
/// fetch (which a censored fresh install can't perform). This is the reachability
/// *floor*: even with `.well-known` unreachable and no cached manifest, the client
/// still has a pool of fronts to probe.
///
/// Seeds are expendable — assume a censor eventually blocks each IP; rotate the pool
/// per release. Adding a front is a one-line append to `VEILConfig.seedRelays`; every
/// consumer (relay selector candidates, TransportRouter pin/SNI, `VeilAlternatesCache`
/// accept-gate, `importBlob` anti-redirection) derives from that list, so nothing else
/// needs touching.
struct VEILSeedRelay {
    /// host:port.
    let address: String
    /// TLS SNI (required — IP-based relays can't use the IP as SNI).
    let sni: String
    /// hex SHA-256 SPKI pin.
    let spki: String
    /// WebTunnel WebSocket resource path; nil if the relay doesn't serve WebTunnel.
    let wtPath: String?
}

// MARK: - VEIL Bridge Configuration
struct VEILConfig {
    /// Primary VEIL endpoint: TLS 1.3 → obfs4 → gRPC (Amsterdam, via Traefik).
    /// Uses `ice.<grpcHost>:443` derived at runtime from GRPCChannelManager.currentHost.
    /// Retired relays are tracked in `retiredRelayHosts` below (not as commented code).

    // The Amsterdam obfs4 relay (ice.ams.konstruct.cc) was retired — see retiredRelayHosts.
    // The main gRPC server is still ams.konstruct.cc (direct path); only the relay is gone.

    // ── Relay: RU veil-front (api.divany-kresla.uk) — the sole VEIL relay ─────
    /// 2026-06-11: VPS repurposed as the **veil-front relay** (honest-front HTTPS +
    /// session-bound ticket auth). It terminates veil-TLS with its own Let's Encrypt
    /// cert and re-wraps gRPC over TLS to ams.konstruct.cc:443 (--backend-tls).
    /// SPKI below is now that veil-front cert. obfs4/WebTunnel are no longer served
    /// here — veil-front wins the coordinator race via `ruRelayVeilFrontTicket`.
    /// 2026-06-14: relay moved to a new VPS (195.133.44.113); cert reissued, so the
    /// pinned SPKI below was rotated. `api.divany-kresla.uk` A-record must point at
    /// the new IP for the on-wire SNI to match a resolvable host.
    static let ruRelayAddress    = "api.divany-kresla.uk:443"
    static let ruRelaySNI        = "api.divany-kresla.uk"
    static let ruRelayPinnedSPKI = "5621e47a745614de08efb054b01388f3bcf32c763ecf5f0aeaeb6b0785ff6861"
    /// Stale obfs4 keypair cert — kept only so the obfs4 probe has a bridge line; it
    /// fails fast (relay no longer speaks obfs4) and veil-front wins the race.
    // The veil-front ticket is per-user auth material — NOT hardcoded here. It is
    // imported out-of-band via a signed config blob (QR / konstruct://veil-config deep
    // link) into VeilTicketStore. See VeilTicketProvisioning.swift.

    /// Ed25519 public key used to verify `.well-known/construct-server` signature.
    /// This is the ONLY value hardcoded permanently — everything else is OTA-updatable.
    /// Generated by: scripts/generate-signing-key.sh in construct-landing repo.
    static let relayConfigSigningKey = "8a0ee71cd95f86a9f6877211accefaff6bb97f3051b3b2141f1c71690b9a2dcf"

    /// Ed25519 bundle-signing public keys pinned at build time (base64, 32 bytes each) —
    /// the keys `identity-service` signs `SenderCertificate`s (and KT tree heads) with.
    /// sealed-sender-resilience lever B: `StealthSenderService.verifyCert` accepts the
    /// fetched-from-well-known key OR any of these pins, so a sealed receive no longer
    /// depends on a live/side-effect fetch of the bundle key (the 2026-07-05 incident:
    /// the key was only ever cached as a side effect of the VEIL relay fetch, so on a
    /// non-VEIL device it was nil and every cert "failed verification").
    ///
    /// Ordered current-first. Rotation is flag-day-free: ship the next key here in an
    /// app update ahead of the server flip, retire the old one after the fleet updates.
    /// MUST track `BUNDLE_SIGNING_KEY` rotations — see
    /// construct-docs/deployment/stealth-token-keys-runbook.md.
    static let pinnedBundleSigningKeys: [String] = [
        "kDGyaafEFExKTdB7MJXl4xYf0pFnxEg7bZJh7BDP9LI=",
    ]

    /// Per-relay obfs4 bridge certs. Empty — obfs4 is retired (excluded from the probe race),
    /// so no bridge certs are shipped. Kept as the lookup surface for `bridgeCertSync`.
    static let hardcodedRelayCerts: [String: String] = [:]

    /// Relays we have permanently retired (e.g. IP blocked by RU DPI). These are filtered
    /// out of every relay source — including stale cached manifests a censored device can no
    /// longer refresh — so the client never wastes a 30–40s VEIL probe + cooldown dialing a
    /// relay that no longer exists. Matched by host, so any `:port` variant is caught.
    static let retiredRelayHosts: Set<String> = [
        "158.160.140.67",        // MSK relay — IP blocked by RU DPI (removed)
        "45.135.233.5",          // SPb relay — IP blocked by RU DPI (removed 2026-05-16)
        "ice.ams.konstruct.cc",  // AMS obfs4 relay — retired (obfs4 disabled); veil-front only now
    ]

    /// True if `address` (host or host:port) points at a retired relay (see `retiredRelayHosts`).
    static func isRetiredRelay(_ address: String) -> Bool {
        let parts = address.split(separator: ":")
        let host = parts.count > 1 ? parts.dropLast().joined(separator: ":") : address
        return retiredRelayHosts.contains(host)
    }

    /// Bundled seed-front pool (EntryDirectory Source 2) — the single source of truth
    /// the address list and the SNI/SPKI/WT dicts below all derive from. Add a bundled
    /// front here and every consumer picks it up; no other edit needed. Keep the primary
    /// (ruRelay*) first — order is the relay selector's tie-break priority.
    static let seedRelays: [VEILSeedRelay] = [
        VEILSeedRelay(address: ruRelayAddress, sni: ruRelaySNI, spki: ruRelayPinnedSPKI, wtPath: "/api/stream"),
        // Append additional bundled fronts here (e.g. co-tenancy relays). Each needs a
        // distinct address, its TLS SNI, and the hex SHA-256 SPKI pin of its live cert.
    ]

    /// Ordered relay candidate list used as a last resort when discovery is unavailable.
    /// Order matters: relays are probed concurrently but this sets tie-break priority.
    static let hardcodedRelayAddresses: [String] = seedRelays.map(\.address)

    /// TLS SNI overrides keyed by relay address string.
    /// Required for IP-based relays (IPs cannot be used as TLS SNI).
    /// Also used for domain-based relays that need explicit SPKI pinning.
    static let hardcodedRelaySNIs: [String: String] = Dictionary(
        seedRelays.map { ($0.address, $0.sni) }, uniquingKeysWith: { first, _ in first })

    /// SPKI pins keyed by relay address. Looked up by makeRelay() for any relay
    /// that appears in hardcodedRelaySNIs.
    static let hardcodedRelaySPKIs: [String: String] = Dictionary(
        seedRelays.map { ($0.address, $0.spki) }, uniquingKeysWith: { first, _ in first })

    /// UserDefaults key where the relay list fetched from the server is cached.
    static let cachedRelayListKey = "construct.ice_relays"

    /// UserDefaults key where the relay-region config fetched from the server is cached.
    /// Value is JSON-encoded array of `ICERelayRegion` (see VeilCertFetcher).
    static let cachedRelayRegionsKey = "construct.ice_relay_regions"

    /// WebTunnel (ICE v2) WebSocket resource paths, keyed by relay address.
    /// When present, makeRelay() activates WebTunnel-first transport for that relay.
    /// Override via `.well-known/construct-server` `ice.relays[].wt_path` without a new build.
    static let hardcodedRelayWTPaths: [String: String] = Dictionary(
        seedRelays.compactMap { r in r.wtPath.map { (r.address, $0) } },
        uniquingKeysWith: { first, _ in first })

    /// Companion obfs4-only ports for CDN-fronted relays. None currently.
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
    /// Override via `.well-known/construct-server` `ice.relay_regions` without a new build.
    /// Only one relay (veil-front) remains, so the region rule just prefers it everywhere.
    static let hardcodedRelayRegions: [VEILRelayRegion] = [
        VEILRelayRegion(tzOffsetMin: -12, tzOffsetMax: 12, preferredRelays: [ruRelayAddress]),
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
    /// Posted when a contact's at-risk (degraded-session) state changes — e.g. after an at-risk
    /// session is auto-upgraded to a fresh one. userInfo: ["userId": String]
    static let sessionAtRiskChanged = Notification.Name("constructSessionAtRiskChanged")
}
