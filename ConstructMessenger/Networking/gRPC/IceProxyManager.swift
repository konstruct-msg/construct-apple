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
    let address: String     // "relay.example.com:443" (TLS mode) or ":9443" (legacy)
    let bridgeCert: String  // base64 cert received from server
    let iatMode: IceIATMode
    /// When set: outer TLS connection is established first using this SNI before
    /// the obfs4 handshake. nil = legacy plain-TCP obfs4 (no outer TLS).
    let tlsServerName: String?

    /// Full bridge line string passed to Rust: "cert=<cert> iat-mode=<n>"
    var bridgeLine: String {
        "cert=\(bridgeCert) iat-mode=\(iatMode.rawValue)"
    }

    init(address: String, bridgeCert: String, iatMode: IceIATMode = .none, tlsServerName: String? = nil) {
        self.id            = UUID()
        self.address       = address
        self.bridgeCert    = bridgeCert
        self.iatMode       = iatMode
        self.tlsServerName = tlsServerName
    }

    // Codable conformance for IceIATMode (stored as rawValue Int)
    enum CodingKeys: String, CodingKey {
        case id, address, bridgeCert, iatMode, tlsServerName
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self, forKey: .id)
        address       = try c.decode(String.self, forKey: .address)
        bridgeCert    = try c.decode(String.self, forKey: .bridgeCert)
        let raw       = (try? c.decode(Int.self, forKey: .iatMode)) ?? 0
        iatMode       = IceIATMode(rawValue: raw) ?? .none
        tlsServerName = try? c.decode(String.self, forKey: .tlsServerName)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(address, forKey: .address)
        try c.encode(bridgeCert, forKey: .bridgeCert)
        try c.encode(iatMode.rawValue, forKey: .iatMode)
        try? c.encode(tlsServerName, forKey: .tlsServerName)
    }
}

/// Builds an `IceRelay` from a server-pushed address string, automatically
/// detecting TLS mode by port: `:443` → TLS-wrapped obfs4 (SNI = hostname),
/// any other port → legacy plain-obfs4.
private func makeRelay(address: String, bridgeCert: String) -> IceRelay {
    // "host:port" — extract hostname to use as SNI for port-443 endpoints.
    let sni: String?
    if address.hasSuffix(":443") {
        sni = address.components(separatedBy: ":").first.flatMap { $0.isEmpty ? nil : $0 }
    } else {
        sni = nil
    }
    return IceRelay(address: address, bridgeCert: bridgeCert, iatMode: .none, tlsServerName: sni)
}

/// Manages the construct-ice local TCP proxy for gRPC obfuscation.
@MainActor
final class IceProxyManager: ObservableObject {
    static let shared = IceProxyManager()
    private init() {}

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var proxyPort: UInt16 = 0
    @Published private(set) var activeRelay: IceRelay?
    @Published private(set) var lastError: String?
    /// True while ICE is in cooldown after a relay failure. Drives the UI directly —
    /// changes to this property cause the Network settings view to re-render.
    @Published private(set) var isOnCooldown: Bool = false

    private var cooldownTask: Task<Void, Never>?

    // MARK: - Persistence keys

    private let enabledKey = "ice_enabled"
    private let relayKey   = "iceActiveRelay"

    /// Prevents duplicate concurrent on-demand start attempts (e.g. when several
    /// RPC calls all fail at the same moment and each tries to start ICE).
    private var isStartingOnDemand = false

    /// Whether the user has enabled ICE obfuscation. Persists across launches.
    /// On macOS, defaults to `true` — no battery penalty, sessions are long-lived.
    /// On iOS, defaults to `false` — opt-in to avoid battery drain on mobile.
    var isEnabled: Bool {
        get {
            #if os(macOS)
            // If the user has never explicitly set this key, default to enabled on macOS
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            #endif
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
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
            return startWithRelayFallback(cert: freshCert)
        }
        return false
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
            // TLS-over-obfs4 mode: outer TLS (SecureTransport, SNI=sni) before obfs4.
            // DPI sees a normal TLS ClientHello on port 443.
            Log.info("🧊 ICE TLS mode → \(relay.address) (SNI: \(sni))", category: "ICE")
            result = relay.bridgeLine.withCString { bridgePtr in
                relay.address.withCString { addrPtr in
                    sni.withCString { sniPtr in
                        ice_proxy_start_tls(bridgePtr, addrPtr, sniPtr, &port)
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
        isRunning   = false
        proxyPort   = 0
        activeRelay = nil
    }

    // MARK: - Relay list

    /// Returns the relay address list: server-cached list first, then hardcoded fallback.
    /// Deduplicates while preserving order (server list takes priority).
    /// The list is then reordered to prefer relays closer to the user's timezone.
    func cachedRelayAddresses() -> [String] {
        let server   = UserDefaults.standard.stringArray(forKey: ICEConfig.cachedRelayListKey) ?? []
        let fallback = ICEConfig.hardcodedRelayAddresses
        var seen = Set<String>()
        let deduped = (server + fallback).filter { seen.insert($0).inserted }
        return Self.sortRelaysByTimezonePreference(deduped)
    }

    /// Reorders relay addresses so that geographically closer relays are tried first.
    /// Uses the device timezone offset as a privacy-preserving location signal —
    /// no GPS, no IP lookup, no server call required.
    ///
    /// Rule priority:
    ///   1. Server-pushed config (`ICEConfig.cachedRelayRegionsKey` in UserDefaults)
    ///   2. Hardcoded fallback (`ICEConfig.hardcodedRelayRegions`)
    ///   3. No match → return relays unchanged
    ///
    /// The first matching rule (tzOffsetMin ≤ currentOffset ≤ tzOffsetMax) wins.
    private static func sortRelaysByTimezonePreference(_ relays: [String]) -> [String] {
        let offsetHours = TimeZone.current.secondsFromGMT() / 3600

        // Load server-pushed regions (if available), fall back to hardcoded rules.
        let regions: [ICERelayRegion]
        if let data = UserDefaults.standard.data(forKey: ICEConfig.cachedRelayRegionsKey),
           let decoded = try? JSONDecoder().decode([ICERelayRegion].self, from: data) {
            regions = decoded
        } else {
            regions = ICEConfig.hardcodedRelayRegions
        }

        guard let match = regions.first(where: { offsetHours >= $0.tzOffsetMin && offsetHours <= $0.tzOffsetMax }) else {
            return relays
        }

        // Bubble the rule's preferred relays to the front, preserve relative order of the rest.
        let preferred = relays.filter { match.preferredRelays.contains($0) }
        let rest      = relays.filter { !match.preferredRelays.contains($0) }
        if !preferred.isEmpty {
            Log.debug("🧊 Timezone UTC+\(offsetHours): preferring relay(s) first: \(preferred)", category: "ICE")
        }
        return preferred + rest
    }

    // MARK: - Multi-endpoint startup

    /// Start the ICE proxy trying the primary TLS endpoint first, then each relay (plain obfs4).
    ///
    /// Connection order (timezone-aware):
    ///   UTC+3 (Russia/Moscow):
    ///     1. MSK relay (plain obfs4) — closest, lowest latency for RU users
    ///     2. Primary: ice.<host>:443 (TLS+obfs4) — if MSK fails
    ///     3. Remaining relays
    ///   Other timezones:
    ///     1. Primary: ice.<host>:443 (TLS+obfs4) — tried twice
    ///     2. Relay 1…N from cachedRelayAddresses()
    ///
    /// Returns `true` if any endpoint started successfully.
    @discardableResult
    private func startWithRelayFallback(cert: String) -> Bool {
        let host = GRPCChannelManager.shared.currentHost
        let iceHost = "ice.\(host)"
        let primary = IceRelay(address: "\(iceHost):443", bridgeCert: cert, iatMode: .none, tlsServerName: iceHost)

        // Build the ordered candidate list.
        // cachedRelayAddresses() already applies timezone-based sorting using server-pushed
        // or hardcoded ICERelayRegion rules. If the first relay in the sorted list is
        // different from the default ordering it means a region rule matched — try relay first.
        let relayAddresses = cachedRelayAddresses()   // timezone-sorted by region rules
        let defaultRelayAddresses = ICEConfig.hardcodedRelayAddresses + (UserDefaults.standard.stringArray(forKey: ICEConfig.cachedRelayListKey) ?? [])
        let preferRelayFirst = !relayAddresses.isEmpty && relayAddresses.first != defaultRelayAddresses.first

        if preferRelayFirst {
            Log.info("🧊 UTC+\(TimeZone.current.secondsFromGMT() / 3600): trying regional relay(s) before Amsterdam primary", category: "ICE")

            // Try the timezone-preferred relay(s) first (normally just MSK).
            for relayAddress in relayAddresses {
                let relayConfig = makeRelay(address: relayAddress, bridgeCert: cert)
                if start(relay: relayConfig) != nil {
                    saveRelay(relayConfig)
                    Log.info("🧊 ICE started via regional relay: \(relayAddress)", category: "ICE")
                    return true
                }
                Log.info("🧊 ICE regional relay \(relayAddress) failed — trying primary", category: "ICE")
            }
        }

        // Primary: TLS-wrapped obfs4 (Amsterdam).  Two attempts — network may be settling.
        if start(relay: primary) != nil {
            saveRelay(primary)
            Log.info("🧊 ICE started via primary: \(iceHost):443", category: "ICE")
            return true
        }
        Log.debug("🧊 ICE primary attempt 1 failed — retrying in 600 ms", category: "ICE")
        Thread.sleep(forTimeInterval: 0.6)
        if start(relay: primary) != nil {
            saveRelay(primary)
            Log.info("🧊 ICE started via primary (retry): \(iceHost):443", category: "ICE")
            return true
        }

        if !preferRelayFirst {
            // Non-CIS path: primary failed, fall through to relay list.
            Log.info("🧊 ICE primary failed — trying relay endpoints", category: "ICE")
            for relayAddress in relayAddresses {
                let relayConfig = makeRelay(address: relayAddress, bridgeCert: cert)
                if start(relay: relayConfig) != nil {
                    saveRelay(relayConfig)
                    Log.info("🧊 ICE started via relay: \(relayAddress)", category: "ICE")
                    return true
                }
                Log.info("🧊 ICE relay \(relayAddress) failed", category: "ICE")
            }
        }

        Log.error("🧊 ICE start failed on all endpoints (1 primary + \(relayAddresses.count) relay(s))", category: "ICE")
        return false
    }

    // MARK: - App-lifecycle entry points

    /// Start with the stored relay (called at app launch if `isEnabled`).
    /// Tries primary TLS → relay fallback → fresh cert → retry, in that order.
    func startIfEnabled() async {
        guard isEnabled else { return }

        // Restore cooldown state from previous session (persisted in UserDefaults by GRPCChannelManager).
        let stored = UserDefaults.standard.double(forKey: "iceRelayLastFailedAt")
        if stored > 0 {
            let remaining = GRPCChannelManager.iceCooldownDuration - (Date().timeIntervalSinceReferenceDate - stored)
            if remaining > 0 {
                enterCooldown(duration: remaining)
            }
        }

        let cert = await getIceBridgeCert()
        if startWithRelayFallback(cert: cert) {
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
        startWithRelayFallback(cert: freshCert)
    }

    /// Auto-start ICE when DPI blocking is detected on a direct connection.
    /// Called by `GRPCChannelManager.performRPC` after a network failure on the direct path.
    /// Does NOT require the user to have `isEnabled = true`; ICE runs temporarily for the session.
    /// If start succeeds, subsequent `performRPC` calls automatically route through ICE until
    /// the proxy is stopped (app restart or user disables ICE in settings).
    func startOnDemandIfNeeded() async {
        // If ICE proxy is running but on cooldown, DPI blocking has been confirmed on the direct
        // path — clear the cooldown so `iceProxyPort()` returns a valid port and the caller
        // retries the RPC through ICE.  This is the right behaviour: cooldown means "the ICE
        // relay was recently flaky", but DPI means "the direct path is always broken".
        if isRunning {
            if isOnCooldown {
                clearCooldown()
                Log.info("🧊 ICE on cooldown but DPI detected — clearing cooldown, routing via ICE", category: "ICE")
            }
            return
        }

        // Another concurrent RPC already kicked off an ICE start — wait for it rather
        // than returning immediately with no proxy port.  We poll on the MainActor so
        // Task.sleep yields to let the active start make progress.
        if isStartingOnDemand {
            let deadline = Date().addingTimeInterval(5)
            while isStartingOnDemand, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            }
            return
        }

        isStartingOnDemand = true
        defer { isStartingOnDemand = false }
        Log.info("🧊 Auto-starting ICE proxy (DPI auto-detection)", category: "ICE")
        let cert = await getIceBridgeCert()
        if startWithRelayFallback(cert: cert) {
            // Persist the enabled state so the UI toggle and traffic-path indicator
            // reflect reality — the user implicitly wants ICE if DPI is active.
            isEnabled = true
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
            Log.info("🧊 ICE auto-started via DPI detection", category: "ICE")
        } else {
            Log.error("🧊 ICE auto-start failed on all endpoints", category: "ICE")
        }
    }

    /// Called when `performRPC` gets ECONNREFUSED on 127.0.0.1 — the Rust proxy process died
    /// while the Swift side still thinks it's running. Force-resets all state and restarts.
    /// Does NOT enter cooldown (cooldown is for relay/cert failures, not local process death).
    func restartAfterCrash() async {
        Log.info("🧊 ICE proxy crashed (ECONNREFUSED on local port) — force-restarting", category: "ICE")
        // Force-stop even if isRunning=true; the Rust side is dead.
        ice_proxy_stop()
        isRunning = false
        proxyPort = 0
        activeRelay = nil
        // Clear any cooldown that was set due to this crash; we want to retry immediately.
        clearCooldown()
        isStartingOnDemand = false
        let cert = await getIceBridgeCert()
        if startWithRelayFallback(cert: cert) {
            Task { await IceCertFetcher.shared.fetchAndCacheRelayList() }
            Log.info("🧊 ICE proxy restarted after crash", category: "ICE")
        } else {
            Log.error("🧊 ICE proxy restart failed after crash", category: "ICE")
        }
    }

    /// Called when DNS resolution fails on the direct TLS path (VPN intercepting DNS).
    /// Clears any cooldown and force-restarts the proxy so gRPC can bypass DNS via ICE.
    /// If the proxy is already running (just on cooldown), skips the restart.
    func forceStartIgnoringCooldown() async {
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
        if startWithRelayFallback(cert: cert) {
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
            isRunning = false
            proxyPort = 0
            activeRelay = nil
            clearCooldown()
            // Brief pause to let the OS release the socket before we re-bind.
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
            let cert = await getIceBridgeCert()
            startWithRelayFallback(cert: cert)
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
        if isEnabled { startWithRelayFallback(cert: cert) }

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
