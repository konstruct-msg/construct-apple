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
    /// ICE is enabled but proxy is temporarily bypassed (cooldown after failure).
    case iceCooldown
    /// ICE is enabled but the proxy has not started yet / is starting.
    case iceConnecting

    var displayTitle: String {
        switch self {
        case .direct:           return "Direct gRPC"
        case .icePrimary:       return "ICE (Primary)"
        case .iceRelay:         return "ICE (Relay)"
        case .iceCooldown:      return "Direct gRPC (ICE recovering)"
        case .iceConnecting:    return "ICE (Connecting…)"
        }
    }

    var displayDetail: String {
        switch self {
        case .direct:                  return "TLS 1.3 · ams.konstruct.cc:443"
        case .icePrimary(let host):    return "TLS + obfs4 · \(host)"
        case .iceRelay(let address):   return "obfs4 relay · \(address)"
        case .iceCooldown:             return "Reconnecting via ICE…"
        case .iceConnecting:           return "Starting obfs4 proxy…"
        }
    }

    var symbolName: String {
        switch self {
        case .direct:        return "network"
        case .icePrimary:    return "lock.shield.fill"
        case .iceRelay:      return "arrow.triangle.2.circlepath.circle.fill"
        case .iceCooldown:   return "exclamationmark.arrow.circlepath"
        case .iceConnecting: return "clock.arrow.circlepath"
        }
    }

    var color: String {   // colour name for SwiftUI, avoid Color dependency here
        switch self {
        case .direct:        return "blue"
        case .icePrimary:    return "green"
        case .iceRelay:      return "purple"
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

    /// Full bridge line string passed to Rust: "cert=<cert> iat-mode=<n>"
    var bridgeLine: String {
        "cert=\(bridgeCert) iat-mode=\(iatMode.rawValue)"
    }

    init(address: String, bridgeCert: String, iatMode: IceIATMode = .none,
         tlsServerName: String? = nil, pinnedSpki: String? = nil) {
        self.id            = UUID()
        self.address       = address
        self.bridgeCert    = bridgeCert
        self.iatMode       = iatMode
        self.tlsServerName = tlsServerName
        self.pinnedSpki    = pinnedSpki
    }

    // Codable conformance for IceIATMode (stored as rawValue Int)
    enum CodingKeys: String, CodingKey {
        case id, address, bridgeCert, iatMode, tlsServerName, pinnedSpki
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self, forKey: .id)
        address       = try c.decode(String.self, forKey: .address)
        bridgeCert    = try c.decode(String.self, forKey: .bridgeCert)
        let raw       = (try? c.decode(Int.self, forKey: .iatMode)) ?? 0
        iatMode       = IceIATMode(rawValue: raw) ?? .none
        tlsServerName = try? c.decode(String.self, forKey: .tlsServerName)
        pinnedSpki    = try? c.decode(String.self, forKey: .pinnedSpki)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(address, forKey: .address)
        try c.encode(bridgeCert, forKey: .bridgeCert)
        try c.encode(iatMode.rawValue, forKey: .iatMode)
        try? c.encode(tlsServerName, forKey: .tlsServerName)
        try? c.encode(pinnedSpki, forKey: .pinnedSpki)
    }
}

/// Builds an `IceRelay` from an address string, automatically detecting TLS mode:
/// `:443` → TLS-wrapped obfs4, any other port → legacy plain-obfs4.
///
/// SNI + pinning priority for `:443` addresses:
/// 1. `IceCertFetcher` cached relay config (fetched from signed construct-server) → preferred.
/// 2. `ICEConfig.hardcodedRelaySNIs[address]` + `ICEConfig.mskRelayPinnedSPKI` → hardcoded fallback.
/// 3. Hostname extracted from address → domain-based relay (no pinning).
private func makeRelay(address: String, bridgeCert: String) -> IceRelay {
    let sni: String?
    let pin: String?
    if address.hasSuffix(":443") {
        if let s = IceCertFetcher.sniSync(for: address), !s.isEmpty {
            sni = s
            pin = IceCertFetcher.spkiPinSync(for: address)
        } else if let explicitSNI = ICEConfig.hardcodedRelaySNIs[address] {
            // Hardcoded fallback: IP-based relay with fake SNI for REALITY-style DPI evasion.
            sni = explicitSNI
            pin = ICEConfig.mskRelayPinnedSPKI.isEmpty ? nil : ICEConfig.mskRelayPinnedSPKI
        } else {
            // Server-pushed relay (domain-based): derive SNI from hostname, no pinning.
            sni = address.components(separatedBy: ":").first.flatMap { $0.isEmpty ? nil : $0 }
            pin = nil
        }
    } else {
        sni = nil
        pin = nil
    }
    return IceRelay(address: address, bridgeCert: bridgeCert, iatMode: .none,
                    tlsServerName: sni, pinnedSpki: pin)
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
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                await self.handleNetworkPathChange()
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var proxyPort: UInt16 = 0
    @Published private(set) var activeRelay: IceRelay?
    @Published private(set) var lastError: String?
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

    // MARK: - Persistence keys

    private let enabledKey = "ice_enabled"
    private let relayKey   = "iceActiveRelay"
    /// Tracks whether `isEnabled` was set by DPI auto-detection (true) or user toggle (false).
    private static let autoDetectedKey = "ice_auto_detected_dpi"
    /// Bump this version to trigger another one-time reset of stale DPI state.
    private static let dpiResetVersion = 1
    /// Bump to trigger migration from old boolean ice_enabled → IceMode tri-state.
    private static let modesMigrationVersion = 1

    /// Prevents duplicate concurrent on-demand start attempts (e.g. when several
    /// RPC calls all fail at the same moment and each tries to start ICE).
    private var isStartingOnDemand = false

    // MARK: - Failed relay tracking
    //
    // When a relay fails in production (obfs4 tunnel times out), its address is
    // blacklisted so the next startWithRelayFallback() picks a different relay
    // instead of re-selecting the same broken one based on TCP latency alone.
    // Entries auto-expire after `relayFailureTTL`.

    /// Maps relay address → failure timestamp. Deprioritized in startWithRelayFallback().
    private var recentlyFailedRelays: [String: Date] = [:]
    /// How long a failed relay stays deprioritized before becoming eligible again.
    private static let relayFailureTTL: TimeInterval = 300  // 5 minutes

    /// Address of the relay that has successfully completed at least one gRPC RPC
    /// this session. In-memory only — resets on app restart.
    /// When the active relay matches, performRPC trusts its obfs4 tunnel and uses
    /// the full RPC timeout. Otherwise a short "probe" timeout detects DPI-blocked
    /// tunnels quickly and triggers inline relay rotation.
    private(set) var verifiedRelayAddress: String?

    /// Whether the currently active relay has been verified by a successful RPC.
    var isCurrentRelayVerified: Bool {
        guard let active = activeRelay?.address else { return false }
        return active == verifiedRelayAddress
    }

    /// Mark the active relay as verified after a successful RPC through ICE.
    func markCurrentRelayVerified() {
        guard let addr = activeRelay?.address, addr != verifiedRelayAddress else { return }
        verifiedRelayAddress = addr
        Log.info("🧊 Relay \(addr) verified (first successful RPC)", category: "ICE")
    }

    /// Mark a relay address as recently failed. Called from GRPCChannelManager.recordICEFailure()
    /// before the restart cycle begins.
    func recordRelayFailure(address: String) {
        recentlyFailedRelays[address] = Date()
        // Prune expired entries.
        let now = Date()
        recentlyFailedRelays = recentlyFailedRelays.filter { now.timeIntervalSince($0.value) < Self.relayFailureTTL }
        Log.info("🧊 Relay \(address) blacklisted for \(Int(Self.relayFailureTTL))s", category: "ICE")
    }

    /// Whether a relay has failed recently and should be tried last.
    private func isRelayRecentlyFailed(_ address: String) -> Bool {
        guard let failedAt = recentlyFailedRelays[address] else { return false }
        return Date().timeIntervalSince(failedAt) < Self.relayFailureTTL
    }

    /// Clear all relay failure tracking (e.g. on network path change — new network may work fine).
    private func clearRelayFailures() {
        guard !recentlyFailedRelays.isEmpty || verifiedRelayAddress != nil else { return }
        recentlyFailedRelays.removeAll()
        verifiedRelayAddress = nil
        Log.info("🧊 Relay failure blacklist + verification cleared", category: "ICE")
    }

    // MARK: - ICE Mode (tri-state)

    /// The current ICE operation mode. Persists across launches via UserDefaults.
    /// `.off` = no ICE, `.auto` = DPI auto-detect (default iOS), `.on` = always ICE (default macOS).
    @Published var mode: IceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: IceMode.defaultsKey)
            // Also keep legacy key in sync for iceProxyPort() fast-path reads.
            UserDefaults.standard.set(mode == .on, forKey: enabledKey)
            // User explicitly changed mode — give relay selection a clean slate.
            clearRelayFailures()
        }
    }

    /// True when DPI blocking was detected during this app session (not persisted).
    /// In `.auto` mode, this is the gate for `iceProxyPort()` — proxy port is only
    /// returned when DPI is confirmed, preventing EU users from routing through ICE.
    @Published private(set) var dpiDetectedThisSession = false

    /// Timestamp of last successful direct probe (TLS handshake). nil if never probed or failed.
    @Published private(set) var lastDirectProbeSuccess: Date?
    /// Timer for periodic direct probing in AUTO mode when ICE is active.
    private var directProbeTask: Task<Void, Never>?

    /// Legacy compatibility: whether ICE should be treated as "enabled" for routing.
    /// - `.off` → false
    /// - `.auto` → true only if DPI detected this session
    /// - `.on` → true always
    var isEnabled: Bool {
        get {
            switch mode {
            case .off:  return false
            case .auto: return dpiDetectedThisSession
            case .on:   return true
            }
        }
        set {
            // Legacy setter for UI compatibility during transition.
            // Maps: true → .on, false → .off (explicit user action).
            mode = newValue ? .on : .off
        }
    }

    /// The current effective routing path for traffic.
    /// Updates automatically because it reads `@Published` properties.
    var currentTrafficPath: TrafficPath {
        guard isRunning, let relay = activeRelay else { return .direct }
        if isOnCooldown { return .iceCooldown }
        if relay.tlsServerName != nil { return .icePrimary(host: relay.address) }
        return .iceRelay(address: relay.address)
    }

    // MARK: - Cooldown management

    /// Enter cooldown mode: UI switches to "ICE recovering", then auto-clears after `duration` seconds.
    /// Called by GRPCChannelManager when a relay failure is detected.
    func enterCooldown(duration: TimeInterval) {
        guard !isOnCooldown else { return }
        isOnCooldown = true
        Log.info("🧊 ICE cooldown started (\(Int(duration))s) — routing via direct gRPC", category: "ICE")
        cooldownTask?.cancel()
        cooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.isOnCooldown = false
            Log.info("🧊 ICE cooldown expired — ICE routing resumes on next connection", category: "ICE")
        }
    }

    /// Manually clear the cooldown (e.g. user taps "Retry ICE" in settings).
    func clearCooldown() {
        cooldownTask?.cancel()
        cooldownTask = nil
        isOnCooldown = false
        UserDefaults.standard.removeObject(forKey: GRPCChannelManager.iceFailedAtKey)
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

    /// Called when ICE handshake fails repeatedly (stale cert after server key rotation).
    /// Clears Keychain cache, fetches fresh cert via .well-known, restarts proxy via fallback chain.
    /// Returns true if a new cert was obtained and proxy was restarted successfully.
    @discardableResult
    func refreshCertAndRestart() async -> Bool {
        Log.info("🧊 ICE cert stale — clearing cache and re-fetching via .well-known", category: "ICE")
        KeychainManager.shared.deleteIceBridgeCert()
        guard let freshCert = await IceCertFetcher.shared.fetchFromHTTPS() else {
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
        stop()
        let cert = await getIceBridgeCert()
        return await startWithRelayFallback(cert: cert)
    }

    // MARK: - Start / Stop

    /// Start the local proxy for the given relay.
    /// - Returns: The local port that gRPC should connect to.
    @discardableResult
    func start(relay: IceRelay) -> UInt16? {
        if isRunning { stop() }
        lastError = nil

        var port: UInt16 = 0
        let result: Int32
        PerformanceMetrics.shared.start(.iceProxyStartBegin, label: relay.address)

        if let sni = relay.tlsServerName {
            if let spki = relay.pinnedSpki {
                // Pinned mode: fake/empty SNI + SPKI cert verification (no CA chain).
                // DPI sees: TLS to IP:443 with Yandex Cloud SNI — looks like CDN traffic.
                Log.info("🧊 ICE TLS+pinned → \(relay.address) (SNI: \(sni.isEmpty ? "<none>" : sni))", category: "ICE")
                result = relay.bridgeLine.withCString { bridgePtr in
                    relay.address.withCString { addrPtr in
                        sni.withCString { sniPtr in
                            spki.withCString { spkiPtr in
                                ice_proxy_start_tls_pinned(bridgePtr, addrPtr, sniPtr, spkiPtr, &port)
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
            isRunning   = true
            proxyPort   = port
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
        clearDPIDetection()
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
    /// Early-exit optimisation: once the first reachable result arrives, a grace timer of
    /// `NetworkTiming.ICE.sortByLatencyEarlyExitDelay` starts. Any probes that haven't
    /// responded by the deadline are treated as unreachable and appended at the end —
    /// they are still tried, just last. This prevents waiting the full `relayLatencyProbeTimeout`
    /// for blocked endpoints (e.g. AMS unreachable in RU) when a relay already responded.
    private static func sortByLatency(_ addresses: [String], timeout: TimeInterval = NetworkTiming.ICE.relayLatencyProbeTimeout) async -> [String] {
        guard !addresses.isEmpty else { return [] }
        var results: [(String, TimeInterval?)] = []
        var earlyExitAfter: Date? = nil

        await withTaskGroup(of: (String, TimeInterval?).self) { group in
            for address in addresses {
                group.addTask { (address, await probeLatency(address: address, timeout: timeout)) }
            }
            for await (addr, lat) in group {
                results.append((addr, lat))
                if lat != nil, earlyExitAfter == nil {
                    earlyExitAfter = Date().addingTimeInterval(NetworkTiming.ICE.sortByLatencyEarlyExitDelay)
                }
                // Once every address has responded, or the early-exit deadline has passed, stop.
                if results.count == addresses.count { break }
                if let deadline = earlyExitAfter, Date() >= deadline {
                    group.cancelAll()
                    break
                }
            }
        }

        // Addresses whose probes were cancelled (didn't make it into `results`) are treated
        // as unreachable — appended last so they're still attempted as a final fallback.
        let probedSet = Set(results.map(\.0))
        let cancelled = addresses.filter { !probedSet.contains($0) }
        let reachable  = results.filter { $0.1 != nil }.sorted { $0.1! < $1.1! }.map(\.0)
        let unreachable = results.filter { $0.1 == nil }.map(\.0) + cancelled
        return reachable + unreachable
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

        // Deduplicated candidate list: primary (AMS) + hardcoded + server-fetched relays.
        var seen = Set<String>()
        var candidates: [String] = []
        let allAddresses = ["\(iceHost):443"] + ICEConfig.hardcodedRelayAddresses
            + (UserDefaults.standard.stringArray(forKey: ICEConfig.cachedRelayListKey) ?? [])
        for addr in allAddresses where seen.insert(addr).inserted { candidates.append(addr) }

        // Probe all endpoints concurrently and sort by TCP latency (fastest first).
        var ordered = await Self.sortByLatency(candidates)

        // Deprioritize relays that failed recently in production — move them to the end.
        // They're still tried as a last resort in case all others fail.
        let notFailed = ordered.filter { !isRelayRecentlyFailed($0) }
        let failed    = ordered.filter { isRelayRecentlyFailed($0) }
        if !failed.isEmpty {
            ordered = notFailed + failed
            Log.info("🧊 Deprioritized recently-failed relay(s): \(failed.joined(separator: ", "))", category: "ICE")
        }

        Log.info("🧊 Relay probe order: \(ordered.joined(separator: " → "))", category: "ICE")

        for address in ordered {
            let relay: IceRelay
            if address == "\(iceHost):443" {
                relay = IceRelay(address: address, bridgeCert: cert, iatMode: .none, tlsServerName: iceHost)
            } else {
                relay = makeRelay(address: address, bridgeCert: cert)
            }
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

        var ordered = await Self.sortByLatency(candidates)
        guard !ordered.isEmpty else { return false }

        // Deprioritize recently-failed relays (same as startWithRelayFallback).
        let notFailed = ordered.filter { !isRelayRecentlyFailed($0) }
        let failed    = ordered.filter { isRelayRecentlyFailed($0) }
        if !failed.isEmpty {
            ordered = notFailed + failed
        }

        let primaryAddress   = ordered[0]
        let secondaryAddress = ordered.count > 1 ? ordered[1] : nil

        // Build relays
        func makeHERelay(_ address: String) -> IceRelay {
            if address == "\(iceHost):443" {
                return IceRelay(address: address, bridgeCert: cert, iatMode: .none, tlsServerName: iceHost)
            }
            return makeRelay(address: address, bridgeCert: cert)
        }

        let primaryRelay = makeHERelay(primaryAddress)

        // Start primary (this maps to PROXY_TLS when address has tlsServerName, else PROXY).
        let primaryPort = start(relay: primaryRelay)
        if let p = primaryPort {
            isRunning  = true
            proxyPort  = p
            activeRelay = primaryRelay
            saveRelay(primaryRelay)
            Log.info("🧊 HE primary started on :\(p) via \(primaryAddress)", category: "ICE")
        } else {
            Log.error("🧊 HE primary failed (\(primaryAddress))", category: "ICE")
        }

        // Start secondary without calling stop() first (we own two separate Rust statics).
        if let secondaryAddress {
            let secondaryRelay = makeHERelay(secondaryAddress)
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
        // For a plain-obfs4 secondary we always use ice_proxy_start (not _tls).
        // If the caller accidentally passes a TLS relay, strip tlsServerName.
        var host = ""
        guard let comps = relay.address.split(separator: ":").map(String.init) as [String]?,
              comps.count == 2,
              let _ = UInt16(comps[1]) else { return nil }
        host = comps[0]

        var outPort: UInt16 = 0
        let result = host.withCString { hostPtr in
            relay.bridgeCert.withCString { certPtr in
                ice_proxy_start(certPtr, hostPtr, &outPort)
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
        // Phase 1: legacy boolean DPI reset (existing migration v1)
        let dpiKey = "ice_dpi_reset_v\(Self.dpiResetVersion)"
        if !UserDefaults.standard.bool(forKey: dpiKey) {
            UserDefaults.standard.set(true, forKey: dpiKey)
            #if os(iOS)
            if UserDefaults.standard.bool(forKey: enabledKey) {
                UserDefaults.standard.set(false, forKey: enabledKey)
                UserDefaults.standard.set(false, forKey: Self.autoDetectedKey)
                Log.info("🧊 Cleared stale ICE auto-detection (DPI reset v\(Self.dpiResetVersion))", category: "ICE")
            }
            #endif
        }

        // Phase 2: migrate to IceMode tri-state
        let modeKey = "ice_mode_migration_v\(Self.modesMigrationVersion)"
        if !UserDefaults.standard.bool(forKey: modeKey) {
            UserDefaults.standard.set(true, forKey: modeKey)
            // Only migrate if mode was never explicitly set
            if UserDefaults.standard.string(forKey: IceMode.defaultsKey) == nil {
                let migrated = IceMode.migrateFromLegacy()
                mode = migrated
                Log.info("🧊 Migrated to IceMode: \(migrated.rawValue)", category: "ICE")
            }
        }
    }

    /// Start with the stored relay (called at app launch).
    /// In `.on` mode: starts ICE immediately.
    /// In `.auto`/`.off` mode: skips (ICE will start on-demand if DPI is detected).
    func startIfEnabled() async {
        migrateToModeIfNeeded()
        guard mode == .on else { return }

        // Restore cooldown state from previous session (persisted in UserDefaults by GRPCChannelManager).
        let stored = UserDefaults.standard.double(forKey: "iceRelayLastFailedAt")
        if stored > 0 {
            let remaining = GRPCChannelManager.iceCooldownDuration - (Date().timeIntervalSinceReferenceDate - stored)
            if remaining > 0 {
                enterCooldown(duration: remaining)
            }
        }

        let cert = await getIceBridgeCert()
        if await startWithRelayFallback(cert: cert) {
            // Background: refresh relay list so it's up-to-date for next time.
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
            return
        }

        // All endpoints failed with current cert. May be stale after key rotation.
        Log.info("🧊 All ICE endpoints failed — fetching fresh cert and retrying", category: "ICE")
        guard let freshCert = await IceCertFetcher.shared.fetchFromHTTPS() else {
            Log.error("🧊 ICE start failed and fresh cert unavailable — proxy not running", category: "ICE")
            return
        }
        KeychainManager.shared.saveIceBridgeCert(freshCert)
        await startWithRelayFallback(cert: freshCert)
    }

    /// Auto-start ICE when DPI blocking is detected on a direct connection.
    /// Called by `GRPCChannelManager.performRPC` after a network failure on the direct path.
    /// Only works in `.auto` mode. Sets `dpiDetectedThisSession` (session-scoped, not persisted).
    /// In `.off` mode: does nothing (user explicitly disabled ICE).
    /// In `.on` mode: should never be called (ICE already running).
    func startOnDemandIfNeeded() async {
        guard mode == .auto else { return }
        await startOnDemandInternal()
    }

    /// Starts ICE as a fast-fallback probe (e.g. for stream open) without confirming DPI.
    /// Use when the direct path looks blocked/slow but we don't yet have a definitive signal.
    /// Only works in `.auto` mode.
    func startEphemeralOnDemandIfNeeded() async {
        guard mode == .auto else { return }
        await startOnDemandInternal(confirmDPI: false)
    }

    private func startOnDemandInternal(confirmDPI: Bool = true) async {
        // If ICE proxy is running but on cooldown, DPI blocking has been confirmed on the direct
        // path — clear the cooldown so `iceProxyPort()` returns a valid port and the caller
        // retries the RPC through ICE.  This is the right behaviour: cooldown means "the ICE
        // relay was recently flaky", but DPI means "the direct path is always broken".
        if isRunning {
            if isOnCooldown {
                clearCooldown()
                Log.info("🧊 ICE on cooldown but DPI detected — clearing cooldown, routing via ICE", category: "ICE")
            }
            if confirmDPI { confirmDPIDetected() }
            return
        }

        // Another concurrent RPC already kicked off an ICE start — wait for it rather
        // than returning immediately with no proxy port.  We poll on the MainActor so
        // Task.sleep yields to let the active start make progress.
        if isStartingOnDemand {
            let deadline = Date().addingTimeInterval(NetworkTiming.ICE.onDemandStartJoinTimeout)
            while isStartingOnDemand, Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(NetworkTiming.ICE.onDemandStartJoinPollInterval * 1_000_000_000))
            }
            return
        }

        isStartingOnDemand = true
        defer { isStartingOnDemand = false }
        Log.info("🧊 Auto-starting ICE proxy (DPI auto-detection, confirmDPI=\(confirmDPI))", category: "ICE")
        let cert = await getIceBridgeCert()
        if await startWithRelayFallback(cert: cert) {
            if confirmDPI { confirmDPIDetected() }
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
            Log.info("🧊 ICE auto-started via DPI detection", category: "ICE")
        } else {
            Log.error("🧊 ICE auto-start failed on all endpoints", category: "ICE")
        }
    }

    /// Mark DPI as detected for this session and start periodic direct probing.
    /// Session-scoped: resets on app restart, so EU users get a clean slate.
    /// Syncs the legacy `ice_enabled` key so `iceProxyPort()` fast-path sees it.
    private func confirmDPIDetected() {
        guard !dpiDetectedThisSession else { return }
        dpiDetectedThisSession = true
        UserDefaults.standard.set(true, forKey: enabledKey)
        Log.info("🧊 DPI confirmed for this session — ICE routing active, starting direct probe timer", category: "ICE")
        startDirectProbeTimer()
    }

    /// Clear DPI detection for this session (direct probe succeeded or mode changed).
    private func clearDPIDetection() {
        dpiDetectedThisSession = false
        if mode == .auto {
            UserDefaults.standard.set(false, forKey: enabledKey)
        }
        stopDirectProbeTimer()
    }

    // MARK: - Direct probe (AUTO mode)

    /// Periodically probes the direct TLS connection to check if DPI blocking has lifted.
    /// When the probe succeeds, deactivates ICE and switches back to direct routing.
    /// Only runs in `.auto` mode while `dpiDetectedThisSession` is true.
    private func startDirectProbeTimer() {
        directProbeTask?.cancel()
        directProbeTask = Task { @MainActor [weak self] in
            // Wait 5 minutes before first probe — give ICE time to stabilize.
            try? await Task.sleep(for: .seconds(300))
            while !Task.isCancelled {
                guard let self, self.mode == .auto, self.dpiDetectedThisSession else { return }
                let success = await Self.probeDirectTLS(
                    host: GRPCChannelManager.shared.currentHost,
                    port: UInt16(GRPCChannelManager.shared.currentPort)
                )
                if success {
                    self.lastDirectProbeSuccess = Date()
                    Log.info("🧊 Direct probe succeeded — deactivating ICE, switching to direct", category: "ICE")
                    self.clearDPIDetection()
                    GRPCChannelManager.shared.invalidatePersistentClient()
                    return
                } else {
                    Log.debug("🧊 Direct probe failed — staying on ICE", category: "ICE")
                }
                // Retry every 5 minutes
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Lightweight direct connection probe: TCP+TLS handshake only (no gRPC).
    /// DPI blocks at TLS level (SNI-based RST), so a successful TLS handshake = no DPI.
    private static func probeDirectTLS(host: String, port: UInt16, timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            let params = NWParameters.tls
            let conn = NWConnection(host: .init(host), port: .init(integerLiteral: port), using: params)
            let flag = OnceResumeFlag()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard flag.trigger() else { return }
                    conn.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard flag.trigger() else { return }
                    conn.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard flag.trigger() else { return }
                conn.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    /// Stop the direct probe timer (called when mode changes or ICE is stopped).
    private func stopDirectProbeTimer() {
        directProbeTask?.cancel()
        directProbeTask = nil
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
        isStartingOnDemand = false
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
    func handleNetworkPathChange() async {
        Log.info("🧊 Network path changed — restarting ICE proxy for new interface", category: "ICE")
        // Stop both proxies; their underlying TCP sockets are dead.
        ice_proxy_stop()
        resetAllProxyState()
        clearCooldown()
        clearRelayFailures()  // new network = clean slate for relay selection
        isStartingOnDemand = false

        // In AUTO mode, reset DPI flag — the new network may not have DPI.
        // Direct will be tried first; if DPI is still present, it re-detects within 4s.
        if mode == .auto {
            clearDPIDetection()
            return
        }

        // In ON mode, restart immediately on the new interface.
        guard mode == .on else { return }
        let cert = await getIceBridgeCert()
        if await startWithRelayFallback(cert: cert) {
            Log.info("🧊 ICE proxy restarted after network path change", category: "ICE")
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
        } else {
            Log.error("🧊 ICE proxy restart failed after network path change", category: "ICE")
        }
    }

    /// Resets all proxy state fields to idle for both primary and secondary proxies.
    /// Call before any restart path (crash, network switch, manual stop).
    @MainActor
    private func resetAllProxyState() {
        isRunning           = false
        proxyPort           = 0
        activeRelay         = nil
        isSecondaryRunning  = false
        secondaryProxyPort  = 0
        secondaryRelay      = nil
    }

    /// Called when DNS resolution fails on the direct TLS path (VPN intercepting DNS).
    /// Clears any cooldown and force-restarts the proxy so gRPC can bypass DNS via ICE.
    /// If the proxy is already running (just on cooldown), skips the restart.
    func forceStartIgnoringCooldown() async {
        guard mode != .off else { return }
        clearCooldown()
        if isRunning {
            // Proxy is alive — clearing cooldown is enough; next makeClient() will use ICE.
            Log.info("🧊 ICE cooldown force-cleared (VPN DNS failure)", category: "ICE")
            return
        }
        // Proxy not running — start it now.
        guard !isStartingOnDemand else { return }
        isStartingOnDemand = true
        defer { isStartingOnDemand = false }
        Log.info("🧊 Force-starting ICE proxy (VPN DNS failure)", category: "ICE")
        let cert = await getIceBridgeCert()
        if await startWithRelayFallback(cert: cert) {
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
        } else {
            Log.error("🧊 ICE force-start failed (VPN DNS failure)", category: "ICE")
        }
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
            iatMode: .none,
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
        if relay.address.hasSuffix(":9443") || relay.tlsServerName == nil {
            let upgraded = makeRelay(address: relay.address.replacingOccurrences(of: ":9443", with: ":443"),
                                     bridgeCert: relay.bridgeCert)
            saveRelay(upgraded)
            Log.info("🧊 Migrated stored relay to TLS mode: \(upgraded.address)", category: "ICE")
            return upgraded
        }
        return relay
    }
}
