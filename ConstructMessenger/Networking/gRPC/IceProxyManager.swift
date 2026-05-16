//
//  IceProxyManager.swift
//  Construct Messenger
//
//  Manages the local obfs4 proxy (construct-ice / ICE).
//
//  Architecture:
//    [Swift gRPC] → 127.0.0.1:proxyPort (plain TCP, no TLS)
//        → [Rust proxy] → Obfs4Stream → relay:443 (obfuscated)
//        → [relay VPS] → main Construct server
//
//  The proxy lives entirely inside libconstruct_core.a (C FFI symbols:
//  ice_proxy_start / ice_proxy_stop / ice_proxy_is_running / ice_proxy_port).
//  GRPCChannelManager checks isRunning and switches targets automatically.
//

import Foundation
import Combine
import Network
import os
import SwiftUI
import CryptoKit
import GRPCCore
import GRPCNIOTransportHTTP2

/// Thread-safe one-shot flag used to prevent double-resuming a CheckedContinuation
/// when multiple concurrent closures (NW state handler + timeout) race to complete.
private final class OnceResumeFlag: @unchecked Sendable {
    private var _triggered = false
    private let lock = NSLock()

    /// Returns `true` the first time it is called, `false` on every subsequent call.
    func trigger() -> Bool {
        lock.withLock {
            guard !_triggered else { return false }
            _triggered = true
            return true
        }
    }
}

/// Describes the current effective traffic routing path.
/// Used for the Network Settings "Connection Route" indicator.
enum TrafficPath: Equatable {
    /// Direct TLS gRPC — no ICE obfuscation.
    case direct
    /// ICE primary: TLS 1.3 → obfs4 → Amsterdam (via Traefik).
    case icePrimary(host: String)
    /// ICE relay: plain obfs4 → Moscow TCP relay → Amsterdam.
    case iceRelay(address: String)
    /// ICE v2 WebTunnel: TLS → WebSocket → relay → server.
    case iceWebTunnel(relay: String)
    /// ICE is enabled but proxy is temporarily bypassed (cooldown after failure).
    case iceCooldown
    /// ICE is enabled but the proxy has not started yet / is starting.
    case iceConnecting

    var displayTitle: String {
        switch self {
        case .direct:           return "Direct gRPC"
        case .icePrimary:       return "ICE (Primary)"
        case .iceRelay:         return "ICE (Relay)"
        case .iceWebTunnel:     return "ICE v2 (WebTunnel)"
        case .iceCooldown:      return "Direct gRPC (ICE recovering)"
        case .iceConnecting:    return "ICE (Connecting…)"
        }
    }

    var displayDetail: String {
        switch self {
        case .direct:                  return "TLS 1.3 · ams.konstruct.cc:443"
        case .icePrimary(let host):    return "TLS + obfs4 · \(host)"
        case .iceRelay(let address):   return "obfs4 relay · \(address)"
        case .iceWebTunnel(let relay): return "wss:// · \(relay)"
        case .iceCooldown:             return "Reconnecting via ICE…"
        case .iceConnecting:           return "Starting obfs4 proxy…"
        }
    }

    var symbolName: String {
        switch self {
        case .direct:        return "network"
        case .icePrimary:    return "lock.shield.fill"
        case .iceRelay:      return "arrow.triangle.2.circlepath.circle.fill"
        case .iceWebTunnel:  return "lock.shield.fill"
        case .iceCooldown:   return "exclamationmark.arrow.circlepath"
        case .iceConnecting: return "clock.arrow.circlepath"
        }
    }

    var color: String {   // colour name for SwiftUI, avoid Color dependency here
        switch self {
        case .direct:        return "blue"
        case .icePrimary:    return "green"
        case .iceRelay:      return "purple"
        case .iceWebTunnel:  return "teal"
        case .iceCooldown:   return "orange"
        case .iceConnecting: return "orange"
        }
    }
}

/// ICE operation mode — controls when and how the obfs4 proxy is used.
///
/// - `off`:  ICE completely disabled. No pre-warm, no auto-detection, no DPI fallback.
///           Use when direct connection works reliably (EU, US, etc.)
/// - `auto`: Direct connection preferred. ICE activates automatically when DPI blocking
///           is detected (session-scoped, not persisted). Periodically probes direct and
///           switches back when blocking lifts. Default on iOS.
/// - `on`:   All traffic always routed through ICE relay. No direct connection attempts.
///           Use behind confirmed censorship (Russia, Iran). Default on macOS.
enum IceMode: String, CaseIterable, Identifiable {
    case off
    case auto
    case on

    var id: String { rawValue }

    /// UserDefaults key for storing the mode.
    static let defaultsKey = "ice_mode"

    /// Platform default: macOS → .on (no battery penalty), iOS → .auto
    static var platformDefault: IceMode {
        #if os(macOS)
        return .on
        #else
        return .auto
        #endif
    }

    /// Migrate from the old boolean `ice_enabled` + `ice_auto_detected_dpi` to `IceMode`.
    /// Called once per migration version. Returns the migrated mode.
    static func migrateFromLegacy() -> IceMode {
        let wasEnabled = UserDefaults.standard.bool(forKey: "ice_enabled")
        let wasAutoDetected = UserDefaults.standard.bool(forKey: "ice_auto_detected_dpi")

        #if os(macOS)
        // macOS previously defaulted to enabled — keep as .on
        return wasEnabled ? .on : .auto
        #else
        if wasEnabled && !wasAutoDetected {
            return .on   // User explicitly enabled ICE
        }
        return .auto     // Default: auto-detect (covers both !enabled and auto-detected)
        #endif
    }
}

/// Higher modes resist timing analysis at the cost of latency.
enum IceIATMode: Int, CaseIterable, Identifiable {
    case none     = 0  // No timing obfuscation (fastest)
    case enabled  = 1  // 0–10 ms jitter between chunks
    case paranoid = 2  // Random chunk sizing + jitter (recommended for China/Iran)

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:     return "Off"
        case .enabled:  return "Enabled (jitter)"
        case .paranoid: return "Paranoid (recommended)"
        }
    }
}

/// Relay configuration — a single obfs4 bridge endpoint.
struct IceRelay: Codable, Identifiable {
    let id: UUID
    let address: String     // "158.160.140.67:443" (TLS mode) or ":9443" (legacy)
    let bridgeCert: String  // base64 cert received from server
    let iatMode: IceIATMode
    /// When set: outer TLS connection is established first using this SNI before
    /// the obfs4 handshake. nil = legacy plain-TCP obfs4 (no outer TLS).
    /// Empty string = TLS but no SNI extension (IP-based ServerName).
    /// Non-empty = SNI sent in ClientHello (use fake domain for REALITY-style evasion).
    let tlsServerName: String?
    /// SHA-256 of DER SubjectPublicKeyInfo (hex). When set, cert is verified by pin
    /// instead of CA chain. Enables use of fake SNI without chain validation errors.
    let pinnedSpki: String?
    /// WebTunnel (ICE v2) WebSocket resource path, e.g. `"/construct-ice"`.
    /// When non-nil, this relay supports the WebTunnel wss:// transport.
    let wtPath: String?
    /// HTTP Host header for the WebTunnel WebSocket upgrade request.
    /// May differ from `tlsServerName` for domain fronting.
    /// Defaults to the relay's hostname when nil.
    let wtHostHeader: String?
    /// Alternative TLS SNI values to try for WebTunnel before falling back to obfs4.
    /// OTA-configurable via relay config. Empty when not applicable.
    let alternativeSNIs: [String]

    /// Full bridge line string passed to Rust: "cert=<cert> iat-mode=<n>"
    var bridgeLine: String {
        "cert=\(bridgeCert) iat-mode=\(iatMode.rawValue)"
    }

    /// Returns true when this relay supports WebTunnel transport (ICE v2).
    var supportsWebTunnel: Bool { wtPath != nil }

    /// True when this relay uses CDN domain fronting: the TLS SNI points to a CDN host
    /// that is different from the relay's own hostname (e.g., MSK behind Yandex CDN).
    ///
    /// Raw obfs4 is **not viable** on CDN-fronted relays because the CDN terminates TLS
    /// at the CDN edge — the inner obfs4 bytes never reach the relay process.
    /// When WebTunnel is blocked on a CDN-fronted relay, the correct action is to rotate
    /// to a direct relay instead of attempting obfs4.
    var isCDNFronted: Bool {
        guard let sni = tlsServerName, !sni.isEmpty else { return false }
        let hostname = address.components(separatedBy: ":").first ?? address
        return sni != hostname
    }

    init(address: String, bridgeCert: String, iatMode: IceIATMode = .none,
         tlsServerName: String? = nil, pinnedSpki: String? = nil,
         wtPath: String? = nil, wtHostHeader: String? = nil,
         alternativeSNIs: [String] = []) {
        self.id             = UUID()
        self.address        = address
        self.bridgeCert     = bridgeCert
        self.iatMode        = iatMode
        self.tlsServerName  = tlsServerName
        self.pinnedSpki     = pinnedSpki
        self.wtPath         = wtPath
        self.wtHostHeader   = wtHostHeader
        self.alternativeSNIs = alternativeSNIs
    }

    // Codable conformance for IceIATMode (stored as rawValue Int)
    enum CodingKeys: String, CodingKey {
        case id, address, bridgeCert, iatMode, tlsServerName, pinnedSpki, wtPath, wtHostHeader
        case alternativeSNIs = "alternativeSNIs"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        address         = try c.decode(String.self, forKey: .address)
        bridgeCert      = try c.decode(String.self, forKey: .bridgeCert)
        let raw         = (try? c.decode(Int.self, forKey: .iatMode)) ?? 1
        iatMode         = IceIATMode(rawValue: raw) ?? .enabled
        tlsServerName   = try? c.decode(String.self, forKey: .tlsServerName)
        pinnedSpki      = try? c.decode(String.self, forKey: .pinnedSpki)
        wtPath          = try? c.decode(String.self, forKey: .wtPath)
        wtHostHeader    = try? c.decode(String.self, forKey: .wtHostHeader)
        alternativeSNIs = (try? c.decode([String].self, forKey: .alternativeSNIs)) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(address, forKey: .address)
        try c.encode(bridgeCert, forKey: .bridgeCert)
        try c.encode(iatMode.rawValue, forKey: .iatMode)
        try? c.encode(tlsServerName, forKey: .tlsServerName)
        try? c.encode(pinnedSpki, forKey: .pinnedSpki)
        try? c.encode(wtPath, forKey: .wtPath)
        try? c.encode(wtHostHeader, forKey: .wtHostHeader)
        if !alternativeSNIs.isEmpty { try? c.encode(alternativeSNIs, forKey: .alternativeSNIs) }
    }
}

/// Builds an `IceRelay` from an address string, automatically detecting TLS mode.
///
/// TLS mode is used for:
///   - Addresses ending in `:443` (standard HTTPS port)
///   - Any address with an explicit SNI in `ICEConfig.hardcodedRelaySNIs` (e.g. `:9443`
///     companion ports that share the relay's TLS cert but bypass CDN)
///   - Any address with server-pushed SNI from `IceCertFetcher`
///
/// Addresses with no SNI config fall back to plain obfs4 (no TLS wrapper).
///
/// SNI + pinning priority for TLS addresses:
/// 1. `IceCertFetcher` cached relay config (fetched from signed construct-server) → preferred.
/// 2. `ICEConfig.hardcodedRelaySNIs[address]` + `ICEConfig.hardcodedRelaySPKIs` → hardcoded fallback.
/// 3. Hostname extracted from address → domain-based relay, no pinning (`:443` only).
private func makeRelay(address: String, bridgeCert: String, forceObfs4: Bool = false) -> IceRelay {
    // Priority: server-pushed per-relay cert → hardcoded cert → AMS cert passed by caller.
    // bridgeCertSync returns hardcodedRelayCerts[address] if no server-pushed cert exists.
    let resolvedCert = IceCertFetcher.bridgeCertSync(for: address) ?? bridgeCert
    let sni: String?
    let pin: String?
    let wtPath: String?
    let wtHostHeader: String?

    // Determine whether this address should use TLS mode:
    //   - Standard :443 port (may be CDN-fronted or direct)
    //   - Any port with a hardcoded SNI override (e.g., :9443 companion ports)
    //   - Any port with a server-pushed SNI from IceCertFetcher
    let serverPushedSNI = IceCertFetcher.sniSync(for: address)
    let hardcodedSNI    = ICEConfig.hardcodedRelaySNIs[address]
    let useTLS          = address.hasSuffix(":443")
                       || serverPushedSNI != nil
                       || hardcodedSNI != nil

    if useTLS {
        if let s = serverPushedSNI, !s.isEmpty {
            sni = s
            pin = IceCertFetcher.spkiPinSync(for: address)
        } else if let explicitSNI = hardcodedSNI {
            // Hardcoded fallback: relay with explicit SNI + SPKI pin.
            // IP-based relays use a fake SNI for REALITY-style DPI evasion;
            // domain-based relays use their own hostname but still need pinning.
            sni = explicitSNI
            pin = ICEConfig.hardcodedRelaySPKIs[address]
        } else {
            // Server-pushed relay (domain-based, :443 only): derive SNI from hostname, no pinning.
            sni = address.components(separatedBy: ":").first.flatMap { $0.isEmpty ? nil : $0 }
            pin = nil
        }
        // WebTunnel (ICE v2) — preferred over obfs4 when available.
        // Skip when forceObfs4 = true (carrier transparent proxy blocked WebSocket UPGRADE).
        // Companion obfs4 ports (:9443) intentionally have no wtPath entry — pure TLS+obfs4.
        wtPath       = forceObfs4 ? nil : IceCertFetcher.wtPathSync(for: address)
        wtHostHeader = forceObfs4 ? nil : IceCertFetcher.wtHostHeaderSync(for: address)
    } else {
        sni = nil
        pin = nil
        wtPath = nil
        wtHostHeader = nil
    }
    // IAT mode: use server-pushed value when available, default to .enabled.
    let iatMode = IceCertFetcher.iatModeSync(for: address) ?? .enabled
    let altSNIs = IceCertFetcher.alternativeSNIsSync(for: address)
    return IceRelay(address: address, bridgeCert: resolvedCert, iatMode: iatMode,
                    tlsServerName: sni, pinnedSpki: pin,
                    wtPath: wtPath, wtHostHeader: wtHostHeader,
                    alternativeSNIs: altSNIs)
}

/// Compute a WebTunnel path auth token for a given time period.
///
/// Mirrors the relay-side computation (`webtunnel_token` in construct-relay):
///   SHA-256( bridge_cert_base64_string || "webtunnel-v1" || period_u64_be )[:8]
/// encoded as 16 lowercase hex characters. Period = unix_seconds / 300 (5 min windows).
///
/// Using the obfs4 bridge cert as seed means no additional shared secret is needed —
/// the cert is already distributed to clients and is relay-specific.
private func webtunnelAuthToken(bridgeCert: String, period: UInt64) -> String {
    var data = Data(bridgeCert.utf8)
    data.append(contentsOf: "webtunnel-v1".utf8)
    withUnsafeBytes(of: period.bigEndian) { data.append(contentsOf: $0) }
    return SHA256.hash(data: data).prefix(8)
        .map { String(format: "%02x", $0) }.joined()
}

/// Manages the construct-ice local TCP proxy for gRPC obfuscation.
@MainActor
final class IceProxyManager: ObservableObject {

    static let shared = IceProxyManager()
    private init() {
        // Load persisted mode (or platform default if never set).
        if let raw = UserDefaults.standard.string(forKey: IceMode.defaultsKey),
           let stored = IceMode(rawValue: raw) {
            self.mode = stored
        } else {
            self.mode = IceMode.platformDefault
        }

        // Restart the ICE proxy whenever the network interface changes.
        // After a cellular ↔ WiFi switch the old TCP tunnel to the relay is dead;
        // the Rust proxy process is still "running" but silently broken.
        // We restart proactively so the next RPC finds a healthy proxy immediately.
        NotificationCenter.default.addObserver(
            forName: .networkPathChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let changeKind = notification.userInfo?["changeKind"]
                as? NetworkReachabilityManager.NetworkChangeKind ?? .newInterface
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                await self.handleNetworkPathChange(changeKind: changeKind)
            }
        }

        // Load persisted relay quality scores from UserDefaults.
        if let data = UserDefaults.standard.data(forKey: Self.qualityScoresDefaultsKey),
           let scores = try? JSONDecoder().decode([String: RelayQualityScore].self, from: data) {
            relayQualityScores = scores
        }
    }

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var proxyPort: UInt16 = 0
    @Published private(set) var activeRelay: IceRelay?
    @Published private(set) var lastError: String?
    /// True when the active transport is WebTunnel (ICE v2) rather than obfs4.
    @Published private(set) var isWebTunnelActive: Bool = false
    /// True while ICE is in cooldown after a relay failure. Drives the UI directly —
    /// changes to this property cause the Network settings view to re-render.
    @Published private(set) var isOnCooldown: Bool = false

    // MARK: - Happy Eyeballs dual-proxy state
    //
    // In dual-proxy mode both PROXY_TLS (primary AMS) and PROXY (secondary relay, e.g. MSK)
    // run simultaneously on different localhost ports.  GRPCChannelManager races all three
    // legs — direct, ICE-TLS, ICE-plain — and uses whichever connects first.
    //
    // `isRunning` and `proxyPort` track the primary (TLS) proxy.
    // `isSecondaryRunning` and `secondaryProxyPort` track the secondary (plain) proxy.

    /// True when the plain-obfs4 secondary relay proxy is running in dual-proxy mode.
    @Published private(set) var isSecondaryRunning = false
    /// Local port of the plain-obfs4 secondary proxy, or 0 when not running.
    @Published private(set) var secondaryProxyPort: UInt16 = 0
    /// The secondary relay configuration (MSK relay or next fastest relay).
    @Published private(set) var secondaryRelay: IceRelay?

    private var cooldownTask: Task<Void, Never>?
    /// Background probe task: periodically checks if direct gRPC is reachable
    /// while running on ICE in `.auto` mode. Cancelled when ICE stops or mode changes.
    private var directProbeTask: Task<Void, Never>?
    /// Pre-warm background task: starts ICE while direct is being attempted.
    private var standbyPrewarmTask: Task<Void, Never>?

    /// ICE is running in standby pre-warm mode: proxy is up but `iceProxyPort()` returns nil.
    /// Routing stays direct until DPI is confirmed (`activateDPIAutoMode`), mode is promoted to
    /// `.on`, or a network switch occurs. Suppresses the "direct path hijack" that would happen
    /// if a pre-warmed proxy were exposed to gRPC before direct is confirmed blocked.
    private(set) var isStandbyPrewarm: Bool = false {
        didSet {
            guard isStandbyPrewarm != oldValue else { return }
            GRPCChannelManager.shared.updateCachedICEStandby(isStandbyPrewarm)
        }
    }

    // MARK: - Persistence keys

    private let enabledKey = "ice_enabled"
    private let relayKey   = "iceActiveRelay"
    /// Bump to trigger migration from old boolean ice_enabled → IceMode tri-state.
    private static let modesMigrationVersion = 1

    /// Persists which path successfully handled gRPC traffic last session.
    /// Used in `.auto` mode to decide the initial routing strategy on launch:
    ///   "ice"    → start ICE proxy proactively (DPI was present last time)
    ///   "direct" → try direct first; ICE starts on demand if DPI detected
    ///   nil      → no history; default to direct-first
    private static let lastSuccessfulPathKey = "ice_last_successful_path"
    static var lastSuccessfulPath: String? {
        get { UserDefaults.standard.string(forKey: lastSuccessfulPathKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastSuccessfulPathKey) }
    }

    // MARK: - Failed relay tracking
    //
    // When a relay fails in production, its address is blacklisted so the next
    // startWithRelayFallback() picks a different relay. TTL is failure-type-aware:
    // stream timeouts (transient) expire in 60 s; TLS/DPI failures in 300 s.
    // This prevents over-penalising a relay for a brief connectivity blip while
    // keeping genuinely broken relays deprioritised long enough to matter.

    /// The reason a relay was blacklisted. Determines how long it stays deprioritised.
    enum RelayFailureType: CustomStringConvertible {
        /// obfs4 / TLS handshake could not be completed — likely DPI or cert mismatch.
        case tlsHandshake
        /// Tunnel was established but an RPC / stream timed out — transient blip.
        case streamTimeout
        /// WebTunnel HTTP upgrade was rejected AND the obfs4 companion also failed.
        case webTunnelBlocked
        /// Explicit DPI pattern detected (multiple direct-path timeouts in .auto mode).
        case dpiDetected

        var ttl: TimeInterval {
            switch self {
            case .tlsHandshake, .dpiDetected: return 300  // 5 min — persistent failure
            case .streamTimeout:              return 60   // 1 min — transient, retry soon
            case .webTunnelBlocked:           return 180  // 3 min — network-specific
            }
        }

        var description: String {
            switch self {
            case .tlsHandshake:    return "tlsHandshake"
            case .streamTimeout:   return "streamTimeout"
            case .webTunnelBlocked:return "webTunnelBlocked"
            case .dpiDetected:     return "dpiDetected"
            }
        }
    }

    private struct RelayBlacklistEntry {
        let type: RelayFailureType
        let timestamp: Date

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) >= type.ttl
        }
    }

    // MARK: - Relay Quality Score

    /// Four-level quality classification derived from historical success/failure counts.
    /// Drives timeout policy and blacklist tolerance per relay.
    enum RelayQuality: Int, Codable, CaseIterable {
        /// No history yet (< 3 RPCs observed).
        case unknown   = -1
        /// < 40 % success rate.
        case poor      =  0
        /// 40–69 % success rate.
        case fair      =  1
        /// 70–89 % success rate.
        case good      =  2
        /// ≥ 90 % success rate.
        case excellent =  3

        /// Whether to trust the relay with the full RPC timeout (vs short probe timeout).
        var useFullTimeout: Bool { self == .excellent || self == .good }

        /// Whether to use the short fetch-missed-messages wall-clock cap.
        var useFastFetchCap: Bool { self == .excellent || self == .good }

        /// Consecutive stream timeouts on the same relay before blacklisting it.
        /// Trusted relays are rotated quickly on failure; unknown/fair relays get an extra chance.
        var blacklistThreshold: Int { (self == .excellent || self == .good) ? 1 : 2 }

        var logLabel: String {
            switch self {
            case .excellent: return "excellent"
            case .good:      return "good"
            case .fair:      return "fair"
            case .poor:      return "poor"
            case .unknown:   return "unknown"
            }
        }

        /// Short badge string shown in Network Settings next to the relay address.
        var badge: String {
            switch self {
            case .excellent: return "★★★★"
            case .good:      return "★★★☆"
            case .fair:      return "★★☆☆"
            case .poor:      return "★☆☆☆"
            case .unknown:   return "----"
            }
        }

        var badgeColor: Color {
            switch self {
            case .excellent: return Color.CT.accent
            case .good:      return Color.CT.accent
            case .fair:      return Color.CT.accentDim
            case .poor:      return Color.CT.danger
            case .unknown:   return Color.CT.textDim
            }
        }
    }

    /// Persisted quality record for a single relay address.
    struct RelayQualityScore: Codable {
        var successfulRPCs: Int      = 0
        var failedRPCs:     Int      = 0
        /// EWMA-smoothed TCP connect latency in milliseconds. 0 = never measured.
        var ewmaLatencyMs:  Double   = 0
        /// When ewmaLatencyMs was last updated (used for cache-freshness check).
        var latencyMeasuredAt: Date  = .distantPast
        var lastUsed:          Date  = .distantPast

        var totalRPCs: Int { successfulRPCs + failedRPCs }

        /// True if the latency measurement is fresh enough to skip TCP probing.
        var hasRecentLatency: Bool {
            ewmaLatencyMs > 0
                && Date().timeIntervalSince(latencyMeasuredAt) < NetworkTiming.ICE.latencyCacheValidity
        }

        var quality: RelayQuality {
            guard totalRPCs >= 3 else { return .unknown }
            let rate = Double(successfulRPCs) / Double(totalRPCs)
            switch rate {
            case 0.9...: return .excellent
            case 0.7...: return .good
            case 0.4...: return .fair
            default:     return .poor
            }
        }

        mutating func applyLatencySample(_ sample: TimeInterval) {
            let ms    = sample * 1000
            let alpha = NetworkTiming.ICE.latencyCacheEWMAAlpha
            ewmaLatencyMs = ewmaLatencyMs > 0 ? alpha * ms + (1 - alpha) * ewmaLatencyMs : ms
            latencyMeasuredAt = Date()
            lastUsed = Date()
        }

        mutating func recordSuccess() { successfulRPCs += 1; lastUsed = Date() }
        mutating func recordFailure()  { failedRPCs    += 1; lastUsed = Date() }
    }

    private static let qualityScoresDefaultsKey = "ice_relay_quality_scores_v1"
    private static let qualityScoresMaxEntries  = 20

    /// Persisted quality scores for known relays. Loaded from UserDefaults at init;
    /// updated and saved after every success/failure RPC through ICE.
    private var relayQualityScores: [String: RelayQualityScore] = [:]

    /// Relay addresses that have completed at least one successful RPC this session.
    /// In-memory only — resets on app restart. Together with persisted quality, drives
    /// `isCurrentRelayVerified`: once a relay proves it works this session it uses full
    /// timeouts even if its historical quality is still `.unknown` (< 3 total RPCs).
    private var sessionVerifiedRelays: Set<String> = []

    // MARK: - Relay Failure Tracking

    /// Maps relay address → blacklist entry. Deprioritised in startWithRelayFallback().
    private var recentlyFailedRelays: [String: RelayBlacklistEntry] = [:]

    /// Relay addresses where WebTunnel was blocked by a carrier transparent HTTP proxy this session.
    /// When set, makeRelay() skips wtPath for these addresses, forcing obfs4 mode.
    /// Cleared on network path change — the new network may allow WebTunnel.
    private var webTunnelBlockedRelays: Set<String> = []

    /// Per-relay index into `IceRelay.alternativeSNIs` for the next SNI rotation attempt.
    /// Incremented each time an alternate SNI is tried. Reset on network change or relay rotation.
    private var relayCurrentSNIIndex: [String: Int] = [:]

    /// Whether the currently active relay has been verified by a successful RPC
    /// either this session or from persisted quality history.
    var isCurrentRelayVerified: Bool {
        guard let active = activeRelay?.address else { return false }
        return sessionVerifiedRelays.contains(active) || qualityForRelay(active).useFullTimeout
    }

    /// Quality level for the currently active relay (persisted history).
    @MainActor var currentRelayQuality: RelayQuality {
        guard let active = activeRelay?.address else { return .unknown }
        return qualityForRelay(active)
    }

    /// Quality level for the given relay address from persisted history.
    func qualityForRelay(_ address: String) -> RelayQuality {
        relayQualityScores[address]?.quality ?? .unknown
    }

    /// Record a successful RPC through ICE. Updates the session-verified set and the
    /// persisted quality score. Triggers side effects on the first success of the session.
    func recordRelaySuccess(address: String, latency: TimeInterval) {
        let wasVerified = sessionVerifiedRelays.contains(address)
        sessionVerifiedRelays.insert(address)

        relayQualityScores[address, default: RelayQualityScore()].recordSuccess()
        if latency > 0 {
            relayQualityScores[address, default: RelayQualityScore()].applyLatencySample(latency)
        }
        pruneAndSaveQualityScores()

        if !wasVerified {
            let q = relayQualityScores[address]?.quality ?? .unknown
            Log.info("🧊 Relay \(address) verified (first successful RPC) — quality: \(q.logLabel)", category: "ICE")
            Self.lastSuccessfulPath = "ice"
            scheduleBackgroundDirectProbe()
        }
    }

    private func pruneAndSaveQualityScores() {
        if relayQualityScores.count > Self.qualityScoresMaxEntries {
            let sorted = relayQualityScores.sorted { $0.value.lastUsed > $1.value.lastUsed }
            relayQualityScores = Dictionary(sorted.prefix(Self.qualityScoresMaxEntries)
                .map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        guard let data = try? JSONEncoder().encode(relayQualityScores) else { return }
        UserDefaults.standard.set(data, forKey: Self.qualityScoresDefaultsKey)
    }

    private static func loadPersistedQualityScores() -> [String: RelayQualityScore] {
        guard let data = UserDefaults.standard.data(forKey: qualityScoresDefaultsKey),
              let scores = try? JSONDecoder().decode([String: RelayQualityScore].self, from: data)
        else { return [:] }
        return scores
    }

    /// Mark the active relay as verified after a successful RPC through ICE.
    /// Legacy entry point used internally and by `GRPCCallExecutor` — now delegates to
    /// `recordRelaySuccess(address:latency:)`.
    @discardableResult
    func markCurrentRelayVerified(latency: TimeInterval = 0) -> Bool {
        guard let addr = activeRelay?.address else { return false }
        recordRelaySuccess(address: addr, latency: latency)
        return true
    }

    /// Mark the active relay as verified after a successful RPC through ICE.

    /// Mark a relay address as recently failed. Called from GRPCChannelManager.recordICEFailure()
    /// before the restart cycle begins.
    ///
    /// - Parameters:
    ///   - address: Relay address string.
    ///   - type: Failure reason — determines the blacklist TTL. Defaults to `.streamTimeout` (60 s).
    func recordRelayFailure(address: String, type: RelayFailureType = .streamTimeout) {
        recentlyFailedRelays[address] = RelayBlacklistEntry(type: type, timestamp: Date())
        // Prune expired entries while we have the dict in hand.
        recentlyFailedRelays = recentlyFailedRelays.filter { !$0.value.isExpired }
        // Persist the failure to quality score history.
        relayQualityScores[address, default: RelayQualityScore()].recordFailure()
        pruneAndSaveQualityScores()
        Log.info("🧊 Relay \(address) blacklisted for \(Int(type.ttl))s [\(type)]", category: "ICE")
    }

    /// Remove a relay from the failure blacklist so it can be retried immediately.
    /// Used after a successful config refresh when the SPKI may have been updated.
    func unblacklistRelay(address: String) {
        guard recentlyFailedRelays[address] != nil else { return }
        recentlyFailedRelays.removeValue(forKey: address)
        Log.info("🧊 Relay \(address) removed from blacklist after config refresh", category: "ICE")
    }

    /// Whether a relay has failed recently enough that it should be tried last.
    private func isRelayRecentlyFailed(_ address: String) -> Bool {
        guard let entry = recentlyFailedRelays[address] else { return false }
        return !entry.isExpired
    }

    /// True when every known relay is in the recently-failed blacklist.
    /// Used by GRPCChannelManager to detect the "all relays exhausted" state and apply
    /// a cooldown before the next rotation attempt — without this guard, rapid cycling
    /// fills the relay's per-IP connection limit (8), making all subsequent attempts fail.
    var allRelaysRecentlyFailed: Bool {
        let host = GRPCChannelManager.shared.currentHost
        let iceHost = "ice.\(host)"
        var seen = Set<String>()
        var all: [String] = []
        for addr in ["\(iceHost):443"] + ICEConfig.hardcodedRelayAddresses
            + (UserDefaults.standard.stringArray(forKey: ICEConfig.cachedRelayListKey) ?? [])
        where seen.insert(addr).inserted { all.append(addr) }
        guard !all.isEmpty else { return false }
        return all.allSatisfy { isRelayRecentlyFailed($0) }
    }

    /// Clear session-scoped relay failure tracking (e.g. on network path change).
    /// Quality scores are NOT cleared — they are persisted historical data.
    private func clearRelayFailures() {
        guard !recentlyFailedRelays.isEmpty || !sessionVerifiedRelays.isEmpty
                || !webTunnelBlockedRelays.isEmpty || !relayCurrentSNIIndex.isEmpty else { return }
        recentlyFailedRelays.removeAll()
        sessionVerifiedRelays.removeAll()   // re-verify on new network
        webTunnelBlockedRelays.removeAll()
        relayCurrentSNIIndex.removeAll()    // DPI profile may differ on new network
        // Quality scores and latency EWMA are kept: historical data remains valid.
        // sortByLatency() will re-probe if latencyMeasuredAt is stale.
        Log.info("🧊 Relay failure blacklist + session verification cleared", category: "ICE")
    }

    // MARK: - ICE Mode (tri-state)

    /// The current ICE operation mode. Persists across launches via UserDefaults.
    /// `.off` = no ICE, `.auto` = DPI auto-detect (default iOS), `.on` = always ICE (default macOS).
    @Published var mode: IceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: IceMode.defaultsKey)
            // Also keep legacy key in sync for iceProxyPort() fast-path reads.
            UserDefaults.standard.set(mode == .on, forKey: enabledKey)
            // Push new mode into GRPCChannelManager's in-memory cache immediately
            // so iceProxyPort() never needs a UserDefaults read on the hot path.
            GRPCChannelManager.shared.updateCachedIceMode(mode)
            // User explicitly changed mode — give relay selection a clean slate.
            clearRelayFailures()

            // Seamless .on → .auto: if ICE is already running, don't tear it down.
            // Keep the existing connection alive and switch to background-probe logic.
            if oldValue == .on, mode == .auto, isRunning {
                Log.info("🧊 Mode .on → .auto — keeping live ICE connection, starting background direct probe", category: "ICE")
                Self.lastSuccessfulPath = "ice"
                scheduleBackgroundDirectProbe()
                return  // skip stop()
            }

            // Seamless .auto → .on: ICE is already running (active or standby) — promote it.
            // No restart needed; just clear standby flag so iceProxyPort() starts returning a port.
            if oldValue == .auto, mode == .on, isRunning {
                if isStandbyPrewarm {
                    applyState(.active(port: proxyPort, webTunnel: isWebTunnelActive))
                    Log.info("🧊 Mode .auto → .on — standby ICE promoted to active", category: "ICE")
                    GRPCChannelManager.shared.invalidatePersistentClient()
                } else {
                    Log.info("🧊 Mode .auto → .on — ICE already active, no restart needed", category: "ICE")
                }
                directProbeTask?.cancel()
                directProbeTask = nil
                return  // skip stop()
            }

            // Cancel probe when leaving .auto or when switching to .on/.off directly.
            if mode != .auto {
                directProbeTask?.cancel()
                directProbeTask = nil
            }
        }
    }

    /// Timestamp of last successful direct probe (TLS handshake). nil if never probed or failed.
    @Published private(set) var lastDirectProbeSuccess: Date?

    var isEnabled: Bool {
        get { mode == .on }
        set { mode = newValue ? .on : .off }
    }

    /// The current effective routing path for traffic.
    /// Updates automatically because it reads `@Published` properties.
    var currentTrafficPath: TrafficPath {
        if isOnCooldown { return .iceCooldown }
        guard isRunning, let relay = activeRelay else {
            if isEnabled { return .iceConnecting }
            return .direct
        }
        if isWebTunnelActive { return .iceWebTunnel(relay: relay.address) }
        if relay.tlsServerName != nil { return .icePrimary(host: relay.address) }
        return .iceRelay(address: relay.address)
    }

    // MARK: - Cooldown management

    /// Enter cooldown mode: UI switches to "ICE recovering", then auto-clears after `duration` seconds.
    /// Called by GRPCChannelManager when a relay failure is detected.
    func enterCooldown(duration: TimeInterval) {
        guard !isOnCooldown else { return }
        applyState(.cooldown)
        Log.info("🧊 ICE cooldown started (\(Int(duration))s) — routing via direct gRPC", category: "ICE")
        cooldownTask?.cancel()
        cooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.applyState(.off)
            Log.info("🧊 ICE cooldown expired — ICE routing resumes on next connection", category: "ICE")
        }
    }

    /// Manually clear the cooldown (e.g. user taps "Retry ICE" in settings).
    func clearCooldown() {
        cooldownTask?.cancel()
        cooldownTask = nil
        applyState(.off)
        GRPCChannelManager.shared.clearICECooldownState()
        Log.info("🧊 ICE cooldown cleared by user", category: "ICE")
    }

    /// Whether a bridge cert is available (from Keychain or hardcoded fallback).
    var hasCert: Bool {
        !bridgeCert().isEmpty
    }

    /// Sync cert read: Keychain → hardcoded. Use when async context unavailable.
    func bridgeCert() -> String {
        if let stored = KeychainManager.shared.loadIceBridgeCert(), !stored.isEmpty {
            return stored
        }
        return ICEConfig.hardcodedBridgeCert
    }

    /// Full async cert chain (levels 2–4 — level 1 is AuthTokensResponse, handled at login):
    ///   2. Keychain cache
    ///   3. https://konstruct.cc/.well-known/ice-cert  (Cloudflare CDN, reachable in Russia)
    ///   4. Hardcoded fallback in binary
    func getIceBridgeCert() async -> String {
        if let cached = KeychainManager.shared.loadIceBridgeCert(), !cached.isEmpty {
            return cached
        }
        if let fetched = await IceCertFetcher.shared.fetchFromHTTPS() {
            KeychainManager.shared.saveIceBridgeCert(fetched)
            return fetched
        }
        Log.info("🧊 Using hardcoded ICE bridge cert (last resort)", category: "ICE")
        return ICEConfig.hardcodedBridgeCert
    }

    /// Called when ICE handshake fails repeatedly (stale cert or SPKI after server key rotation).
    /// Clears Keychain cache, fetches fresh obfs4 cert AND relay TLS config (SPKI pins) from .well-known,
    /// unblacklists any relay whose config was refreshed, then restarts proxy via fallback chain.
    /// Returns true if a new cert was obtained and proxy was restarted successfully.
    @discardableResult
    func refreshCertAndRestart() async -> Bool {
        Log.info("🧊 ICE recovery — refreshing cert + relay config via .well-known", category: "ICE")
        KeychainManager.shared.deleteIceBridgeCert()

        // Fetch both obfs4 cert AND relay TLS config (SPKI pins) concurrently.
        async let certTask = IceCertFetcher.shared.fetchFromHTTPS()
        async let configTask = IceCertFetcher.shared.fetchAndCacheRelayConfig()
        let (freshCert, freshRelays) = await (certTask, configTask)

        // Unblacklist any relay that appears in the fresh config.
        // If a relay failed due to stale SPKI, the cache is now updated; a retry is warranted.
        if let relays = freshRelays {
            let failedAddresses = recentlyFailedRelays.keys
            for address in failedAddresses {
                if relays.contains(where: { $0.addressWithPort == address }) {
                    unblacklistRelay(address: address)
                }
            }
        }

        guard let freshCert else {
            Log.error("🧊 Failed to fetch fresh ICE cert — proxy not restarted", category: "ICE")
            return false
        }
        KeychainManager.shared.saveIceBridgeCert(freshCert)
        if isEnabled {
            return await startWithRelayFallback(cert: freshCert)
        }
        return false
    }

    /// Rotates to the next available relay without re-fetching the certificate.
    /// Used for inline relay rotation in performRPC when a relay's obfs4 tunnel
    /// is DPI-blocked but the cert itself is still valid.
    /// Returns true if a different relay was started successfully.
    @discardableResult
    func rotateToNextRelay() async -> Bool {
        // Don't call stop() — we want to bypass the `isRunning` guard and reset directly.
        ice_proxy_stop()
        resetAllProxyState()
        let cert = await getIceBridgeCert()
        return await startWithRelayFallback(cert: cert)
    }

    /// Called when WebTunnel returns a non-200 HTTP status code (carrier transparent proxy
    /// intercepted the WebSocket UPGRADE).
    ///
    /// **SNI rotation first**: if this relay has untried `alternativeSNIs`, restarts WebTunnel
    /// with the next SNI before falling back to obfs4. Domain-fronting rotations can bypass
    /// SNI-based DPI blocks without abandoning WebTunnel entirely.
    ///
    /// **obfs4 fallback**: after all alternate SNIs are exhausted (or if none are configured),
    /// restarts the same relay in obfs4 mode. obfs4 is a binary protocol that carrier transparent
    /// proxies cannot inspect.
    ///
    /// **CDN-fronted relays** (e.g. MSK behind Yandex CDN): CDN terminates TLS at the edge so
    /// raw obfs4 bytes never reach the relay process. Switches to a companion obfs4 port that
    /// connects directly to the relay VM, bypassing the CDN.
    ///
    /// Marks the relay address in `webTunnelBlockedRelays` so subsequent
    /// `startWithRelayFallback()` calls also bypass WebTunnel on this network.
    /// Clears on network path change — new network may allow WebTunnel.
    ///
    /// - Returns: true if a usable transport (alternate SNI or obfs4) started successfully.
    func retryCurrentRelayAsObfs4(hintAddress: String? = nil) async -> Bool {
        // Prefer current live state. If networkPathChanged raced and already called
        // resetAllProxyState() between the caller's webTunnelActive read and this call,
        // fall back to reconstructing the relay from the hint address captured by the caller.
        let relay: IceRelay
        if isWebTunnelActive, let active = activeRelay {
            relay = active
        } else if let addr = hintAddress, !addr.isEmpty,
                  let cert = ICEConfig.hardcodedRelayCerts[addr] {
            Log.info("🧊 WebTunnel retry: activeRelay was reset (network change race) — recovering from hint \(addr)", category: "ICE")
            relay = makeRelay(address: addr, bridgeCert: cert)
        } else {
            return false
        }

        webTunnelBlockedRelays.insert(relay.address)

        // ── SNI rotation: try alternate SNIs before falling back to obfs4 ────────────────
        // This handles SNI-based DPI blocks (e.g. GFW blocking specific WebTunnel domains)
        // without abandoning the more covert WebTunnel transport entirely.
        if let altSNI = nextAlternativeSNI(for: relay) {
            Log.info("🧊 WebTunnel blocked — trying alternate SNI \(altSNI) on \(relay.address)", category: "ICE")
            ice_proxy_stop()
            resetAllProxyState()
            let altRelay = IceRelay(address: relay.address, bridgeCert: relay.bridgeCert,
                                    iatMode: relay.iatMode, tlsServerName: altSNI,
                                    pinnedSpki: relay.pinnedSpki,
                                    wtPath: relay.wtPath, wtHostHeader: altSNI,
                                    alternativeSNIs: relay.alternativeSNIs)
            if start(relay: altRelay) != nil {
                saveRelay(altRelay)
                Log.info("🧊 ICE WebTunnel active via alternate SNI \(altSNI) on \(relay.address)", category: "ICE")
                return true
            }
            Log.info("🧊 Alternate SNI \(altSNI) also failed — continuing to obfs4 fallback", category: "ICE")
        }

        // ── CDN-fronted relays ────────────────────────────────────────────────────────────
        // CDN terminates TLS at the edge — obfs4 bytes inside the TLS tunnel never reach
        // the relay process. Switch to a companion obfs4 port (direct VM access, no CDN).
        if relay.isCDNFronted {
            if let companionAddr = ICEConfig.hardcodedRelayObfs4Companions[relay.address] {
                Log.info("🧊 CDN-fronted relay \(relay.address) — switching to companion obfs4 port \(companionAddr)", category: "ICE")
                ice_proxy_stop()
                resetAllProxyState()
                let obfs4Relay = makeRelay(address: companionAddr, bridgeCert: relay.bridgeCert)
                if start(relay: obfs4Relay) != nil {
                    saveRelay(obfs4Relay)
                    Log.info("🧊 ICE obfs4 active via companion port \(companionAddr) (bypassing CDN)", category: "ICE")
                    return true
                }
                Log.error("🧊 ICE companion obfs4 port \(companionAddr) also failed — will rotate", category: "ICE")
                return false
            }
            Log.info("🧊 CDN-fronted relay \(relay.address) — no companion obfs4 port configured, rotating", category: "ICE")
            return false
        }

        // ── obfs4 fallback ────────────────────────────────────────────────────────────────
        Log.info("🧊 WebTunnel blocked (all SNIs exhausted) — retrying \(relay.address) via obfs4", category: "ICE")
        ice_proxy_stop()
        resetAllProxyState()
        let obfs4Relay = makeRelay(address: relay.address, bridgeCert: relay.bridgeCert, forceObfs4: true)
        if start(relay: obfs4Relay) != nil {
            saveRelay(obfs4Relay)
            Log.info("🧊 ICE obfs4 active on \(relay.address) (WebTunnel blocked by carrier)", category: "ICE")
            return true
        }
        Log.error("🧊 ICE obfs4 also failed on \(relay.address) — will rotate to next relay", category: "ICE")
        return false
    }

    /// Returns the next untried alternative SNI for the given relay, advancing the index.
    /// Returns nil when all alternatives have been tried or the relay has none.
    private func nextAlternativeSNI(for relay: IceRelay) -> String? {
        let alts = relay.alternativeSNIs
        guard !alts.isEmpty else { return nil }
        let idx = relayCurrentSNIIndex[relay.address, default: 0]
        guard idx < alts.count else { return nil }
        relayCurrentSNIIndex[relay.address] = idx + 1
        return alts[idx]
    }

    // MARK: - Start / Stop

    /// Start the local proxy for the given relay.
    /// - Returns: The local port that gRPC should connect to.
    @discardableResult
    func start(relay: IceRelay) -> UInt16? {
        if isRunning { stop() }
        lastError = nil

        var port: UInt16 = 0
        var result: Int32 = 0
        PerformanceMetrics.shared.start(.iceProxyStartBegin, label: relay.address)

        // WebTunnel (ICE v2) — try first when available. Requires TLS config.
        // Falls through to obfs4 when wt_path is absent or WebTunnel fails.
        if let wtPath = relay.wtPath, relay.tlsServerName != nil {
            let sni        = relay.tlsServerName ?? ""
            let spki       = relay.pinnedSpki ?? ""
            let hostHeader = relay.wtHostHeader ?? ""

            // Append time-based auth token derived from the relay's obfs4 bridge cert.
            // The relay verifies it with the same HMAC — stops bots and scanners.
            let period = UInt64(Date().timeIntervalSince1970) / 300
            let token = webtunnelAuthToken(bridgeCert: relay.bridgeCert, period: period)
            let authPath = wtPath + "/" + token

            Log.info("🧊 ICE WebTunnel → \(relay.address) (SNI: \(sni.isEmpty ? "<none>" : sni), path: \(authPath))", category: "ICE")
            result = relay.address.withCString { addrPtr in
                sni.withCString { sniPtr in
                    spki.withCString { spkiPtr in
                        hostHeader.withCString { hostPtr in
                            authPath.withCString { pathPtr in
                                ice_proxy_start_webtunnel(addrPtr, sniPtr, spkiPtr, hostPtr, pathPtr, &port)
                            }
                        }
                    }
                }
            }
            if result == 0 {
                PerformanceMetrics.shared.end(.iceProxyStartBegin, endEvent: .iceProxyStartEnd, label: relay.address)
                applyState(.active(port: port, webTunnel: true))
                activeRelay = relay
                return port
            }
            Log.error("🧊 ICE WebTunnel failed (\(result)), falling back to obfs4", category: "ICE")
        }

        isWebTunnelActive = false  // transient reset before obfs4/TLS attempt

        if let sni = relay.tlsServerName {
            if let spki = relay.pinnedSpki {
                // Pinned mode: fake/empty SNI + SPKI cert verification + Chrome131 TLS profile.
                // DPI sees: TLS ClientHello with Chrome 131 fingerprint — indistinguishable from
                // real browser traffic. Fake SNI further disguises the destination.
                Log.info("🧊 ICE TLS+pinned → \(relay.address) (SNI: \(sni.isEmpty ? "<none>" : sni))", category: "ICE")
                result = relay.bridgeLine.withCString { bridgePtr in
                    relay.address.withCString { addrPtr in
                        sni.withCString { sniPtr in
                            spki.withCString { spkiPtr in
                                "chrome131".withCString { profilePtr in
                                    ice_proxy_start_tls_profiled(bridgePtr, addrPtr, sniPtr, spkiPtr, profilePtr, &port)
                                }
                            }
                        }
                    }
                }
            } else {
                // Unpinned TLS mode (server-pushed domain relays): CA-chain validation.
                Log.info("🧊 ICE TLS mode → \(relay.address) (SNI: \(sni))", category: "ICE")
                result = relay.bridgeLine.withCString { bridgePtr in
                    relay.address.withCString { addrPtr in
                        sni.withCString { sniPtr in
                            ice_proxy_start_tls(bridgePtr, addrPtr, sniPtr, &port)
                        }
                    }
                }
            }
        } else {
            Log.info("🧊 ICE plain-obfs4 mode → \(relay.address)", category: "ICE")
            result = relay.bridgeLine.withCString { bridgePtr in
                relay.address.withCString { addrPtr in
                    ice_proxy_start(bridgePtr, addrPtr, &port)
                }
            }
        }

        if result == 0 {
            PerformanceMetrics.shared.end(.iceProxyStartBegin, endEvent: .iceProxyStartEnd, label: relay.address)
            applyState(.active(port: port, webTunnel: false))
            activeRelay = relay
            return port
        } else {
            lastError = result == 2 ? "Failed to start proxy (network unreachable)" : "Failed to start proxy (check bridge cert)"
            return nil
        }
    }

    /// Stop the running proxy.
    func stop() {
        guard isRunning else { return }
        ice_proxy_stop()
        resetAllProxyState()
    }

    // MARK: - Relay list

    /// Returns the relay address list: server-cached list first, then hardcoded fallback.
    /// Deduplicates while preserving order (server list takes priority).
    /// The list is then reordered to prefer relays closer to the user's timezone.
    func cachedRelayAddresses() -> [String] {
        let server   = UserDefaults.standard.stringArray(forKey: ICEConfig.cachedRelayListKey) ?? []
        let fallback = ICEConfig.hardcodedRelayAddresses
        var seen = Set<String>()
        return (server + fallback).filter { seen.insert($0).inserted }
    }

    /// Returns the OTA-cached relay-region rules, falling back to hardcoded defaults.
    private func effectiveRelayRegions() -> [ICERelayRegion] {
        if let data = UserDefaults.standard.data(forKey: ICEConfig.cachedRelayRegionsKey),
           let regions = try? JSONDecoder().decode([ICERelayRegion].self, from: data) {
            return regions
        }
        return ICEConfig.hardcodedRelayRegions
    }

    /// Reorders `candidates` so that region-preferred relay addresses appear first.
    /// Matches the device's current UTC offset against the first applicable rule.
    /// Candidates not listed in `preferredRelays` keep their relative order at the end.
    private func applyRegionPreference(to candidates: [String]) -> [String] {
        let tzOffset = TimeZone.current.secondsFromGMT() / 3600
        guard let rule = effectiveRelayRegions().first(where: {
            tzOffset >= $0.tzOffsetMin && tzOffset <= $0.tzOffsetMax
        }) else { return candidates }
        let preferred = rule.preferredRelays
        let front = preferred.filter { candidates.contains($0) }
        let back  = candidates.filter { !preferred.contains($0) }
        return front + back
    }

    // MARK: - Latency probing

    /// Opens a TCP connection to `host:port` and returns the time-to-ready, or nil if unreachable
    /// within `timeout` seconds. Used to order relay candidates before starting the proxy.
    private static func probeLatency(address: String, timeout: TimeInterval = NetworkTiming.ICE.relayLatencyProbeTimeout) async -> TimeInterval? {
        let parts = address.split(separator: ":")
        guard parts.count >= 2, let port = NWEndpoint.Port(String(parts.last!)) else { return nil }
        let hostname = String(parts.dropLast().joined(separator: ":"))

        return await withCheckedContinuation { continuation in
            let conn = NWConnection(host: .init(hostname), port: port, using: .tcp)
            // Protect the one-shot resume flag against concurrent access from the
            // stateUpdateHandler (NW queue) and the timeout (utility queue).
            let flag = OnceResumeFlag()
            let start = CFAbsoluteTimeGetCurrent()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard flag.trigger() else { return }
                    conn.cancel()
                    continuation.resume(returning: CFAbsoluteTimeGetCurrent() - start)
                case .failed, .cancelled:
                    guard flag.trigger() else { return }
                    continuation.resume(returning: nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard flag.trigger() else { return }
                conn.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    /// Probes all `addresses` concurrently and returns them sorted by TCP latency (fastest first).
    /// Unreachable endpoints (probe timed out) are placed at the end so they are still tried.
    ///
    /// Cache-aware: addresses with a valid EWMA entry (< 5 min old) are not re-probed.
    /// Only stale or uncached addresses are probed; results are merged with the cache.
    /// EWMA is updated with alpha=0.3 on every fresh measurement.
    ///
    /// Early-exit optimisation: once the first reachable result arrives, a grace timer of
    /// `NetworkTiming.ICE.sortByLatencyEarlyExitDelay` starts. Any probes that haven't
    /// responded by the deadline are treated as unreachable and appended at the end —
    /// they are still tried, just last. This prevents waiting the full `relayLatencyProbeTimeout`
    /// for blocked endpoints (e.g. AMS unreachable in RU) when a relay already responded.
    private func sortByLatency(_ addresses: [String], timeout: TimeInterval = NetworkTiming.ICE.relayLatencyProbeTimeout) async -> [String] {
        guard !addresses.isEmpty else { return [] }

        // Split into addresses that have a fresh latency entry and those that need probing.
        var cachedEntries:   [(String, TimeInterval)] = []
        var toProbe:         [String] = []

        for address in addresses {
            if let score = relayQualityScores[address], score.hasRecentLatency {
                cachedEntries.append((address, score.ewmaLatencyMs / 1000))
            } else {
                toProbe.append(address)
            }
        }

        var probeResults: [(String, TimeInterval?)] = []
        var earlyExitAfter: Date? = nil

        if !toProbe.isEmpty {
            await withTaskGroup(of: (String, TimeInterval?).self) { group in
                for address in toProbe {
                    group.addTask { (address, await Self.probeLatency(address: address, timeout: timeout)) }
                }
                for await (addr, lat) in group {
                    probeResults.append((addr, lat))
                    if lat != nil, earlyExitAfter == nil {
                        earlyExitAfter = Date().addingTimeInterval(NetworkTiming.ICE.sortByLatencyEarlyExitDelay)
                    }
                    if probeResults.count == toProbe.count { break }
                    if let deadline = earlyExitAfter, Date() >= deadline {
                        group.cancelAll()
                        break
                    }
                }
            }

            // Update quality scores with fresh probe results (EWMA latency only).
            for (addr, lat) in probeResults {
                guard let sample = lat else { continue }
                relayQualityScores[addr, default: RelayQualityScore()].applyLatencySample(sample)
            }
            if !probeResults.isEmpty { pruneAndSaveQualityScores() }
        }

        if !cachedEntries.isEmpty {
            let skipped = cachedEntries.map { "\($0.0) (\(Int($0.1 * 1000))ms cached)" }.joined(separator: ", ")
            Log.debug("🧊 Latency cache hit for: \(skipped)", category: "ICE")
        }

        // Merge: cached entries + fresh probe results (reachable) + unreachable
        let freshReachable = probeResults.filter { $0.1 != nil }
        let allReachable: [(String, TimeInterval)] = (cachedEntries + freshReachable.map { ($0.0, $0.1!) })
            .sorted { $0.1 < $1.1 }

        let probedSet = Set(probeResults.map(\.0))
        let cancelled = toProbe.filter { !probedSet.contains($0) }
        let unreachable = probeResults.filter { $0.1 == nil }.map(\.0) + cancelled

        return allReachable.map(\.0) + unreachable
    }

    // MARK: - Multi-endpoint startup

    /// Starts the ICE proxy on the best available endpoint.
    ///
    /// All candidates (primary AMS + all known relays) are probed concurrently via TCP connect.
    /// The fastest-responding endpoint is tried first — no hardcoded geographic heuristics.
    /// Unreachable endpoints (probe timed out) are still attempted at the end as a last resort.
    ///
    /// Returns `true` if any endpoint started successfully.
    @discardableResult
    private func startWithRelayFallback(cert: String) async -> Bool {
        let host    = GRPCChannelManager.shared.currentHost
        let iceHost = "ice.\(host)"

        // Fast path: if there's a stored relay from the last successful start and it's
        // not on the recent-failure list, try it immediately without probing all endpoints.
        // This eliminates the 300-400ms sortByLatency pass on every repeat ICE start
        // (network switch, crash recovery, relay rotation).
        if let stored = loadStoredRelay(), !isRelayRecentlyFailed(stored.address) {
            let relay = makeRelay(address: stored.address, bridgeCert: cert,
                                  forceObfs4: webTunnelBlockedRelays.contains(stored.address))
            if start(relay: relay) != nil {
                saveRelay(relay)
                Log.info("🧊 ICE fast-started via cached relay \(relay.address)", category: "ICE")
                return true
            }
            Log.info("🧊 Cached relay \(stored.address) failed — probing all endpoints", category: "ICE")
        }

        // Deduplicated candidate list: primary (AMS) + hardcoded + server-fetched relays.
        var seen = Set<String>()
        var candidates: [String] = []
        let allAddresses = ["\(iceHost):443"] + ICEConfig.hardcodedRelayAddresses
            + (UserDefaults.standard.stringArray(forKey: ICEConfig.cachedRelayListKey) ?? [])
        for addr in allAddresses where seen.insert(addr).inserted { candidates.append(addr) }

        // Probe all endpoints concurrently and sort by TCP latency (fastest first).
        // Region preference is applied first so that region-preferred relays win tie-breaks.
        var ordered = await sortByLatency(applyRegionPreference(to: candidates))
        let notFailed = ordered.filter { !isRelayRecentlyFailed($0) }
        let failed    = ordered.filter { isRelayRecentlyFailed($0) }
        if !failed.isEmpty {
            if notFailed.isEmpty {
                // All relays recently failed. Among them, prefer WebTunnel-capable relays first:
                // CDN-fronted HTTPS WebSocket is immune to TLS fingerprint DPI (obfs4 TLS profile
                // can be identified over time; WebTunnel uses standard HTTPS and is CDN-fronted).
                // start() falls through to TLS+obfs4 automatically if WebTunnel itself fails.
                let failedWT   = failed.filter { IceCertFetcher.wtPathSync(for: $0) != nil && !webTunnelBlockedRelays.contains($0) }
                let failedNoWT = failed.filter { IceCertFetcher.wtPathSync(for: $0) == nil || webTunnelBlockedRelays.contains($0) }
                ordered = failedWT + failedNoWT
            } else {
                ordered = notFailed + failed
            }
            Log.info("🧊 Deprioritized recently-failed relay(s): \(failed.joined(separator: ", "))", category: "ICE")
        }

        Log.info("🧊 Relay probe order: \(ordered.joined(separator: " → "))", category: "ICE")

        for address in ordered {
            let relay = makeRelay(address: address, bridgeCert: cert, forceObfs4: webTunnelBlockedRelays.contains(address))
            if start(relay: relay) != nil {
                saveRelay(relay)
                Log.info("🧊 ICE started via \(address)", category: "ICE")
                return true
            }
            Log.info("🧊 ICE \(address) failed — trying next", category: "ICE")
        }

        Log.error("🧊 ICE start failed on all \(ordered.count) endpoint(s)", category: "ICE")
        return false
    }

    /// Starts **both** the primary (TLS) and secondary (plain) ICE proxies simultaneously
    /// for Happy Eyeballs 3-way race mode.
    ///
    /// - The primary proxy targets the fastest latency-probed relay (TLS preferred).
    /// - The secondary proxy targets the next fastest relay using plain obfs4.
    /// - GRPCChannelManager can then race `direct`, `ICE-TLS`, and `ICE-plain` in parallel.
    /// - If the secondary relay fails to start, the function still succeeds if primary started.
    ///
    /// Returns `true` if at least one proxy started.
    @MainActor
    @discardableResult
    func startBothRelaysForHappyEyeballs(cert: String) async -> Bool {
        let host    = GRPCChannelManager.shared.currentHost
        let iceHost = "ice.\(host)"

        var seen = Set<String>()
        var candidates: [String] = []
        let allAddresses = ["\(iceHost):443"] + ICEConfig.hardcodedRelayAddresses
            + (UserDefaults.standard.stringArray(forKey: ICEConfig.cachedRelayListKey) ?? [])
        for addr in allAddresses where seen.insert(addr).inserted { candidates.append(addr) }

        var ordered = await sortByLatency(applyRegionPreference(to: candidates))
        guard !ordered.isEmpty else { return false }
        let notFailed = ordered.filter { !isRelayRecentlyFailed($0) }
        let failed    = ordered.filter { isRelayRecentlyFailed($0) }
        if !failed.isEmpty {
            if notFailed.isEmpty {
                let failedWT   = failed.filter { IceCertFetcher.wtPathSync(for: $0) != nil && !webTunnelBlockedRelays.contains($0) }
                let failedNoWT = failed.filter { IceCertFetcher.wtPathSync(for: $0) == nil || webTunnelBlockedRelays.contains($0) }
                ordered = failedWT + failedNoWT
            } else {
                ordered = notFailed + failed
            }
        }

        let primaryAddress   = ordered[0]
        let secondaryAddress = ordered.count > 1 ? ordered[1] : nil

        let primaryRelay = makeRelay(address: primaryAddress, bridgeCert: cert, forceObfs4: webTunnelBlockedRelays.contains(primaryAddress))

        // Start primary (this maps to PROXY_TLS when address has tlsServerName, else PROXY).
        let primaryPort = start(relay: primaryRelay)  // sets isRunning, proxyPort, activeRelay via applyState()
        if let _ = primaryPort {
            saveRelay(primaryRelay)
            Log.info("🧊 HE primary started on :\(proxyPort) via \(primaryAddress)", category: "ICE")
        } else {
            Log.error("🧊 HE primary failed (\(primaryAddress))", category: "ICE")
        }

        // Start secondary without calling stop() first (we own two separate Rust statics).
        if let secondaryAddress {
            let secondaryRelay = makeRelay(address: secondaryAddress, bridgeCert: cert, forceObfs4: webTunnelBlockedRelays.contains(secondaryAddress))
            let secondaryPort = startSecondary(relay: secondaryRelay)
            if let sp = secondaryPort {
                isSecondaryRunning = true
                self.secondaryProxyPort = sp
                self.secondaryRelay    = secondaryRelay
                Log.info("🧊 HE secondary started on :\(sp) via \(secondaryAddress)", category: "ICE")
            } else {
                Log.info("🧊 HE secondary failed (\(secondaryAddress)) — single-proxy fallback", category: "ICE")
            }
        }

        return primaryPort != nil || secondaryProxyPort > 0
    }

    /// Starts a proxy instance for use as the *secondary* (plain obfs4) leg in dual-proxy
    /// happy-eyeballs mode. Unlike `start(relay:)`, this always targets the `PROXY` (plain)
    /// static — so it won't collide with a concurrently running PROXY_TLS instance.
    ///
    /// If a plain proxy is already running its port is returned immediately (idempotent).
    @MainActor
    private func startSecondary(relay: IceRelay) -> UInt16? {
        // ice_proxy_start(bridge_line, relay_addr, port_out)
        // bridge_line = "cert=<base64> iat-mode=<N>" (relay.bridgeLine)
        // relay_addr  = "host:port"                  (relay.address)
        var outPort: UInt16 = 0
        let result = relay.bridgeLine.withCString { bridgeLinePtr in
            relay.address.withCString { addrPtr in
                ice_proxy_start(bridgeLinePtr, addrPtr, &outPort)
            }
        }
        guard result == 0, outPort > 0 else { return nil }
        return outPort
    }

    // MARK: - App-lifecycle entry points

    /// One-time migration: move from old boolean `ice_enabled` + `ice_auto_detected_dpi`
    /// to the new `IceMode` tri-state. Also clears stale DPI auto-detection from the
    /// "connection preface" false-positive era.
    private func migrateToModeIfNeeded() {
        let modeKey = "ice_mode_migration_v\(Self.modesMigrationVersion)"
        if !UserDefaults.standard.bool(forKey: modeKey) {
            UserDefaults.standard.set(true, forKey: modeKey)
            if UserDefaults.standard.string(forKey: IceMode.defaultsKey) == nil {
                let migrated = IceMode.migrateFromLegacy()
                mode = migrated
                Log.info("🧊 Migrated to IceMode: \(migrated.rawValue)", category: "ICE")
            }
        }
    }

    /// Start with the stored relay (called at app launch).
    /// In `.on` mode: starts ICE immediately.
    /// In `.auto` mode with prior "ice" path memory: starts ICE proactively to avoid DPI detection delay.
    /// In `.auto` without memory or `.off`: skips (ICE will start on-demand if needed).
    func startIfEnabled() async {
        migrateToModeIfNeeded()

        // If already running in active mode (not standby), no restart needed.
        if isRunning, !isStandbyPrewarm { return }

        // No device keys → app is in onboarding/first-run state. ICE serves no purpose
        // without an auth session, and attempting to connect causes a visible hang
        // (obfs4 handshake timeout). Registration flows use startEphemeralOnDemandIfNeeded().
        guard KeychainManager.shared.isDeviceRegistered() else {
            Log.info("🧊 ICE startup skipped — device not registered", category: "ICE")
            return
        }

        // Full start: mode == .on, or .auto with known-ICE history.
        let shouldStartFull = mode == .on || (mode == .auto && Self.lastSuccessfulPath == "ice")
        if shouldStartFull {
            let cert = await getIceBridgeCert()
            if await startWithRelayFallback(cert: cert) {
                Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
                return
            }
            Log.info("🧊 All ICE endpoints failed — fetching fresh cert and retrying", category: "ICE")
            guard let freshCert = await IceCertFetcher.shared.fetchFromHTTPS() else {
                Log.error("🧊 ICE start failed and fresh cert unavailable — proxy not running", category: "ICE")
                return
            }
            KeychainManager.shared.saveIceBridgeCert(freshCert)
            await startWithRelayFallback(cert: freshCert)
            return
        }

        // Standby pre-warm: .auto mode + direct/unknown history.
        // Start ICE in the background immediately — iceProxyPort() is suppressed while
        // isStandbyPrewarm is true, so gRPC continues routing direct until DPI is confirmed.
        // No artificial delay: the direct connection already starts first (Happy Eyeballs
        // 250ms stagger in the connect path), and standby ICE runs without blocking it.
        guard mode == .auto, !isRunning else { return }
        standbyPrewarmTask?.cancel()
        standbyPrewarmTask = Task { [weak self] in
            guard let self, !Task.isCancelled, mode == .auto, !isRunning else { return }
            Log.info("🧊 Starting ICE standby pre-warm (auto mode, direct history)", category: "ICE")
            // Pre-warm flag is set here; applyState(.standby) needs a port which isn't
            // known yet. Set isStandbyPrewarm directly — applyState() will set it again
            // once the port is allocated by startWithRelayFallback().
            isStandbyPrewarm = true
            let cert = await getIceBridgeCert()
            let started = await startWithRelayFallback(cert: cert)
            if started {
                // startWithRelayFallback → start(relay:) called applyState(.active(…)).
                // Elevate back to standby to suppress iceProxyPort() until DPI confirmed.
                applyState(.standby(port: proxyPort))
                Log.info("🧊 ICE standby pre-warm ready — waiting for DPI confirmation", category: "ICE")
                Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
            } else {
                applyState(.off)
                Log.info("🧊 ICE standby pre-warm failed — will start on demand if DPI detected", category: "ICE")
            }
        }
    }

    /// Called when consecutive direct stream failures indicate DPI blocking (`.auto` mode only).
    /// Starts the ICE proxy so `GRPCChannelManager.iceProxyPort()` returns a port on the next
    /// connection. State is session-scoped: not persisted and resets on next app launch.
    func activateDPIAutoMode() async {
        guard mode == .auto else { return }

        // If ICE is already pre-warmed in standby, promote it instantly — no startup delay.
        if isRunning, isStandbyPrewarm {
            standbyPrewarmTask?.cancel()
            standbyPrewarmTask = nil
            applyState(.active(port: proxyPort, webTunnel: isWebTunnelActive))
            Self.lastSuccessfulPath = "ice"
            GRPCChannelManager.shared.invalidatePersistentClient()
            Log.info("🧊 DPI confirmed — standby ICE promoted to active (instant failover)", category: "ICE")
            return
        }

        guard !isRunning else { return }
        Log.info("🧊 DPI suspected — activating ICE for this session (auto mode)", category: "ICE")

        let cert = await getIceBridgeCert()
        if await startWithRelayFallback(cert: cert) {
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
            return
        }
        // Cert may be stale — try fetching a fresh one before giving up.
        Log.info("🧊 ICE start failed with cached cert — fetching fresh cert", category: "ICE")
        guard let freshCert = await IceCertFetcher.shared.fetchFromHTTPS() else {
            Log.error("🧊 ICE start failed (auto mode) — no fresh cert available", category: "ICE")
            return
        }
        KeychainManager.shared.saveIceBridgeCert(freshCert)
        await startWithRelayFallback(cert: freshCert)
    }

    /// Called when `performRPC` gets ECONNREFUSED on 127.0.0.1 — the Rust proxy process died
    /// while the Swift side still thinks it's running. Force-resets all state and restarts.
    /// Does NOT enter cooldown (cooldown is for relay/cert failures, not local process death).
    func restartAfterCrash() async {
        Log.info("🧊 ICE proxy crashed (ECONNREFUSED on local port) — force-restarting", category: "ICE")
        // Force-stop both primary and secondary; the Rust side is dead.
        ice_proxy_stop()
        resetAllProxyState()
        // Clear any cooldown that was set due to this crash; we want to retry immediately.
        clearCooldown()
        let cert = await getIceBridgeCert()
        if await startWithRelayFallback(cert: cert) {
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
            Log.info("🧊 ICE proxy restarted after crash", category: "ICE")
        } else {
            Log.error("🧊 ICE proxy restart failed after crash", category: "ICE")
        }
    }

    /// Called when the network interface changes (cellular ↔ WiFi, VPN on/off).
    /// The existing TCP tunnel to the relay is dead even if `ice_proxy_is_running()` still
    /// returns 1 (the Rust goroutine hasn't discovered the broken connection yet).
    /// We force-restart proactively so the next RPC finds a healthy proxy immediately.
    @MainActor
    func handleNetworkPathChange(changeKind: NetworkReachabilityManager.NetworkChangeKind = .newInterface) async {
        switch changeKind {
        case .newInterface:
            Log.info("🧊 Network path changed (new interface) — full ICE reset", category: "ICE")
            ice_proxy_stop()
            resetAllProxyState()
            clearCooldown()
            clearRelayFailures()   // relay DPI profile may differ on new interface

        case .pathTopology:
            // VPN toggle or IP rotation: same interface, same DPI environment.
            // Keep relay blacklist and quality scores — relay reachability is unchanged.
            // Just stop the proxy (TCP tunnel is dead) and clear cooldown.
            Log.info("🧊 Network path changed (topology/VPN) — partial ICE reset (blacklist preserved)", category: "ICE")
            ice_proxy_stop()
            resetAllProxyState()
            clearCooldown()
        }

        // Restart ICE if: always-on OR auto mode with a remembered ICE path.
        guard mode == .on || (mode == .auto && Self.lastSuccessfulPath == "ice") else { return }

        // Spread reconnects across clients to avoid thundering-herd.
        // New interface → wider window (0-2s); topology change → tighter window (0-0.5s).
        let maxDelay: TimeInterval = (changeKind == .newInterface) ? 2.0 : 0.5
        let startDelay = NetworkTiming.randomDelay(max: maxDelay)
        if startDelay > 0.05 {
            Log.debug("🧊 Network-change ICE restart staggered by \(String(format: "%.2f", startDelay))s", category: "ICE")
            try? await Task.sleep(for: .seconds(startDelay))
            guard !Task.isCancelled else { return }
        }

        let cert = await getIceBridgeCert()
        if await startWithRelayFallback(cert: cert) {
            Log.info("🧊 ICE proxy restarted after network path change", category: "ICE")
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
        } else {
            Log.error("🧊 ICE proxy restart failed after network path change", category: "ICE")
        }
    }

    // MARK: - Background direct probe (auto mode)

    /// Record that a direct gRPC stream just opened successfully.
    /// Called from `MessageStreamTransport` when the stream's first response
    /// arrives and we're routing via direct (no ICE proxy).
    @MainActor
    func recordDirectStreamConnected() {
        guard mode == .auto else { return }
        Self.lastSuccessfulPath = "direct"
        directProbeTask?.cancel()
        directProbeTask = nil
        // If ICE was pre-warming in standby, stop it — direct path is confirmed working.
        if isRunning, isStandbyPrewarm {
            standbyPrewarmTask?.cancel()
            standbyPrewarmTask = nil
            // applyState(.off) via stop() → resetAllProxyState()
            stop()
            Log.info("🧊 Direct stream confirmed — standby ICE stopped (saving resources)", category: "ICE")
        } else {
            Log.debug("🧊 Direct stream verified — last path = direct", category: "ICE")
        }
    }

    /// Schedule a repeating background probe that checks if direct gRPC is reachable
    /// while we're routing through ICE in `.auto` mode.
    ///
    /// Uses a two-step probe to avoid false positives from TLS-only checks:
    ///   Step 1: Plain TLS handshake (fast, no auth needed)
    ///   Step 2: Real gRPC call 30s later (confirms HTTP/2 not DPI-blocked)
    ///
    /// Only if BOTH steps succeed does the path record "direct" and switch on the
    /// next natural reconnect.  The current live ICE connection is never torn down.
    @MainActor
    func scheduleBackgroundDirectProbe() {
        guard mode == .auto else { return }
        directProbeTask?.cancel()
        directProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(NetworkTiming.ICE.directProbeInterval))
                guard !Task.isCancelled else { break }
                guard let self, self.mode == .auto, self.isRunning else { break }

                // Step 1: TLS handshake
                guard await self.probeDirectTLSConnection() else {
                    Log.debug("🧊 Direct probe step 1 (TLS) failed — staying on ICE", category: "ICE")
                    continue
                }
                Log.info("🧊 Direct probe step 1 (TLS) succeeded — waiting \(Int(NetworkTiming.ICE.directProbeGRPCDelay))s before step 2 (gRPC)", category: "ICE")

                // Debounce: wait before step 2 to avoid acting on a transient TLS blip
                try? await Task.sleep(for: .seconds(NetworkTiming.ICE.directProbeGRPCDelay))
                guard !Task.isCancelled else { break }
                guard self.mode == .auto, self.isRunning else { break }

                // Step 2: real gRPC call (proves HTTP/2 not DPI-blocked)
                if await self.probeDirectGRPCConnection() {
                    Log.info("🧊 Direct probe step 2 (gRPC) succeeded — switching to direct on next reconnect", category: "ICE")
                    await MainActor.run { self.recordDirectStreamConnected() }
                    break
                } else {
                    Log.info("🧊 Direct probe step 2 (gRPC) failed — TLS works but gRPC is DPI-blocked; staying on ICE", category: "ICE")
                    // Continue probing — DPI may be intermittent or temporarily active
                }
            }
        }
    }

    /// Perform a single TLS handshake to the main gRPC server without going through ICE.
    /// Returns true if the handshake completes (direct path is not DPI-blocked).
    private func probeDirectTLSConnection() async -> Bool {
        let host = GRPCChannelManager.shared.currentHost
        let port = GRPCChannelManager.shared.currentPort
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let params = NWParameters.tls
        let conn = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
            using: params
        )
        return await withCheckedContinuation { cont in
            let flag = OnceResumeFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if flag.trigger() { cont.resume(returning: true);  conn.cancel() }
                case .failed:
                    if flag.trigger() { cont.resume(returning: false); conn.cancel() }
                case .cancelled:
                    if flag.trigger() { cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            Task {
                try? await Task.sleep(for: .seconds(NetworkTiming.ICE.directProbeTimeout))
                if flag.trigger() { cont.resume(returning: false); conn.cancel() }
            }
        }
    }

    /// Step 2 of the two-step direct probe.
    /// Makes a real gRPC call on a temporary direct-only channel (bypassing ICE).
    /// Returns true if any gRPC-level response arrives — even UNAUTHENTICATED or NOT_FOUND
    /// counts as success because it proves HTTP/2 is not DPI-blocked.
    /// Returns false only on transport-level failure (connection refused, timeout).
    private func probeDirectGRPCConnection() async -> Bool {
        guard let client = try? GRPCChannelManager.shared.makeDirectProbeClient() else { return false }
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        return await withThrowingTaskGroup(of: Bool?.self) { group in
            // Transport task: drives the HTTP/2 connection; errors surfaced here are transport-level.
            group.addTask {
                do {
                    try await client.runConnections()
                    return nil
                } catch is CancellationError {
                    return nil
                } catch {
                    return false  // transport-level error = gRPC path blocked
                }
            }

            // Probe task: make one gRPC call; any gRPC response = HTTP/2 works.
            group.addTask {
                let keyClient = Shared_Proto_Services_V1_KeyService.Client(wrapping: client)
                var req = Shared_Proto_Services_V1_GetPreKeyCountRequest()
                req.deviceID = deviceId
                do {
                    _ = try await keyClient.getPreKeyCount(request: .init(message: req))
                    // Successful call: direct gRPC is fully operational.
                } catch let e as RPCError where e.code != .unavailable && e.code != .deadlineExceeded {
                    // Any gRPC error except transport failures: HTTP/2 works, gRPC frames pass DPI.
                    // e.g. UNAUTHENTICATED, NOT_FOUND, PERMISSION_DENIED all count as success.
                }  catch {
                    // Transport/timeout failure: gRPC may be blocked.
                    client.beginGracefulShutdown()
                    return false
                }
                client.beginGracefulShutdown()
                return true
            }

            // Timeout task
            group.addTask {
                try? await Task.sleep(for: .seconds(NetworkTiming.ICE.directProbeGRPCTimeout))
                client.beginGracefulShutdown()
                return false
            }

            var result = false
            while let next = try? await group.next() {
                if let r = next {
                    result = r
                    group.cancelAll()
                    break
                }
            }
            return result
        }
    }

    // MARK: - State machine

    /// Explicit connection states replacing the 5 implicit boolean flags.
    ///
    /// Valid transitions:
    ///   off  ──────────────────────► active(...)
    ///   off  ──────────────────────► standby(...)
    ///   off  ──────────────────────► cooldown
    ///   standby ──────────────────► active(...)
    ///   standby ──────────────────► off
    ///   active  ──────────────────► off
    ///   active  ──────────────────► cooldown
    ///   cooldown ─────────────────► off
    enum ConnectionState: Equatable {
        /// No proxy running; gRPC routes direct or ICE is not available.
        case off
        /// ICE proxy pre-warming in standby (`isStandbyPrewarm = true`).
        /// The proxy is running but gRPC is NOT routed through it yet.
        case standby(port: UInt16)
        /// ICE proxy is active and gRPC routes through it.
        case active(port: UInt16, webTunnel: Bool)
        /// Exponential-backoff cooldown after consecutive failures.
        case cooldown
    }

    /// Current stable state, derived from the four source-of-truth `@Published` flags.
    /// Use this for logic; set state via `applyState(_:)` only.
    var connectionState: ConnectionState {
        if isOnCooldown { return .cooldown }
        guard isRunning else { return .off }
        if isStandbyPrewarm { return .standby(port: proxyPort) }
        return .active(port: proxyPort, webTunnel: isWebTunnelActive)
    }

    /// The single point where published connection flags are mutated.
    /// Calling this ensures all flags are always set consistently.
    private func applyState(_ state: ConnectionState) {
        switch state {
        case .off:
            isRunning        = false
            proxyPort        = 0
            isOnCooldown     = false
            isStandbyPrewarm = false
            isWebTunnelActive = false
        case .standby(let port):
            isRunning        = true
            proxyPort        = port
            isOnCooldown     = false
            isStandbyPrewarm = true
            isWebTunnelActive = false
        case .active(let port, let webTunnel):
            isRunning        = true
            proxyPort        = port
            isOnCooldown     = false
            isStandbyPrewarm = false
            isWebTunnelActive = webTunnel
        case .cooldown:
            isRunning        = false
            proxyPort        = 0
            isOnCooldown     = true
            isStandbyPrewarm = false
            isWebTunnelActive = false
        }
    }

    /// Resets all proxy state fields to idle for both primary and secondary proxies.
    /// Call before any restart path (crash, network switch, manual stop).
    @MainActor
    private func resetAllProxyState() {
        applyState(.off)
        activeRelay         = nil
        isSecondaryRunning  = false
        secondaryProxyPort  = 0
        secondaryRelay      = nil
        standbyPrewarmTask?.cancel()
        standbyPrewarmTask  = nil
    }

    /// Called on app foreground to verify the ICE proxy process is actually alive.
    /// iOS may kill background threads; `isRunning` may be stale. Restarts if dead.
    func verifyAliveOrRestart() async {
        guard isRunning else { return }
        // Ask the Rust side — if it disagrees with our Swift state, the process died in background.
        if ice_proxy_is_running() == 0 {
            Log.info("🧊 ICE proxy found dead on foreground — restarting", category: "ICE")
            // Always call stop() to flush any leftover Rust state even when the proxy died.
            ice_proxy_stop()
            resetAllProxyState()
            clearCooldown()
            // Brief pause to let the OS release the socket before we re-bind.
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
            let cert = await getIceBridgeCert()
            await startWithRelayFallback(cert: cert)
        }
    }

    // MARK: - Server-provided configuration

    /// Called after login/register/recovery with the cert from `AuthTokensResponse`.
    /// Saves the cert, refreshes the relay list, and starts the proxy if ICE is enabled.
    func configureFromServer(cert: String) {
        guard !cert.isEmpty else { return }
        KeychainManager.shared.saveIceBridgeCert(cert)
        let host = GRPCChannelManager.shared.currentHost
        let iceHost = "ice.\(host)"
        let relay = IceRelay(
            address: "\(iceHost):443",
            bridgeCert: cert,
            iatMode: .enabled,
            tlsServerName: iceHost
        )
        saveRelay(relay)
        if isEnabled { Task { await self.startWithRelayFallback(cert: cert) } }

        // Background: refresh relay list now that we're authenticated and can reach AMS.
        Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
    }

    func saveRelay(_ relay: IceRelay) {
        if let data = try? JSONEncoder().encode(relay) {
            UserDefaults.standard.set(data, forKey: relayKey)
        }
    }

    func loadStoredRelay() -> IceRelay? {
        guard let data = UserDefaults.standard.data(forKey: relayKey),
              let relay = try? JSONDecoder().decode(IceRelay.self, from: data) else { return nil }
        // Migrate stored relays that still use legacy port 9443 (plain obfs4, no TLS wrapper).
        // Upgrade to port 443 with TLS SNI — all relays now run TLS-over-obfs4 via Traefik.
        // Exception: known companion obfs4 addresses (e.g. mskRelayObfs4Address = "IP:9443")
        // are intentionally on non-443 ports with TLS config — do not migrate those.
        let isLegacyPlainObfs4 = (relay.address.hasSuffix(":9443") || relay.tlsServerName == nil)
                               && ICEConfig.hardcodedRelaySNIs[relay.address] == nil
        if isLegacyPlainObfs4 {
            let upgraded = makeRelay(address: relay.address.replacingOccurrences(of: ":9443", with: ":443"),
                                     bridgeCert: relay.bridgeCert)
            saveRelay(upgraded)
            Log.info("🧊 Migrated stored relay to TLS mode: \(upgraded.address)", category: "ICE")
            return upgraded
        }
        return relay
    }
}
