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
//  The proxy lives entirely inside libconstruct_core.a. All C FFI calls
//  (`ice_proxy_start*`, `ice_proxy_stop`, `ice_proxy_is_running`) are routed
//  through the `IceProxyRuntime` protocol — see `NativeIceProxyRuntime.swift`.
//  GRPCChannelManager checks isRunning and switches targets automatically.
//

import Foundation
import Combine
import Network
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
private func makeRelay(address: String, bridgeCert: String, forceObfs4: Bool = false, manifestId: String? = nil) -> IceRelay {
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
                    alternativeSNIs: altSNIs, manifestId: manifestId)
}



/// Manages the construct-ice local TCP proxy for gRPC obfuscation.
@MainActor
final class IceProxyManager: ObservableObject {

    static let shared = IceProxyManager()

    // MARK: - Runtime

    /// Narrow C FFI boundary. Inject a mock at init for testing; default is the real Rust backend.
    private let runtime: any IceProxyRuntime

    private init(runtime: any IceProxyRuntime = NativeIceProxyRuntime()) {
        self.runtime = runtime
        // Load persisted mode (or platform default if never set).
        self.mode = IceProxyStore.loadMode()

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
                await self.stop()
                await ConnectionLoop.shared.reset()
            }
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

    private var cooldownTask: Task<Void, Never>?
    /// Background probe task: periodically checks if direct gRPC is reachable
    /// while running on ICE in `.auto` mode. Cancelled when ICE stops or mode changes.
    /// Monotonically incrementing epoch for proxy-start sequences.
    /// Every reset-and-restart bumps this; callers capture it before their first `await`
    /// and abort if it has changed by the time they would call `start()`.
    private var proxyStartGeneration: Int = 0
    
    /// Coalescing rotation task handle. Multiple concurrent rotation requests collapse
    /// to a single rotation to avoid tearing down the proxy multiple times in rapid succession.
    private var rotationTask: Task<Void, Never>?
    
    @discardableResult
    private func bumpStartGeneration() -> Int {
        proxyStartGeneration += 1
        return proxyStartGeneration
    }

    /// WebTunnel active status captured when entering standby pre-warm.
    /// Restored when the standby proxy is promoted to active (dpiConfirmed / mode .on).

    // MARK: - Persisted path memory

    /// Persists which path successfully handled gRPC traffic last session.
    /// Used in `.auto` mode to choose initial routing on launch.
    static var lastSuccessfulPath: String? {
        get { IceProxyStore.lastSuccessfulPath }
        set { IceProxyStore.lastSuccessfulPath = newValue }
    }

    /// Persisted quality scores for known relays. Loaded from UserDefaults at init;
    /// updated and saved after every success/failure RPC through ICE.
    var isCurrentRelayVerified: Bool {
        get async { await ConnectionLoop.shared.isCurrentRelayVerified }
    }

    /// Quality level for the currently active relay (persisted history).
    @MainActor var currentRelayQuality: RelayQuality {
        guard let active = activeRelay?.address else { return .unknown }
        return qualityForRelay(active)
    }

    /// Quality level for the given relay address from persisted history.
    func qualityForRelay(_ address: String) -> RelayQuality {
        .unknown  // ConnectionLoop uses simple failure counting
    }

    /// Record a successful RPC through ICE. Updates the session-verified set and the
    /// persisted quality score. Triggers side effects on the first success of the session.
    func recordRelaySuccess(address: String, latency: TimeInterval) {
        Task { await ConnectionLoop.shared.recordRelaySuccess(address: address, latency: latency) }
    }


    // MARK: - Cert expiry monitoring

    /// Checks TLS certificate expiry for all known relays from the server-pushed config.
    /// - Expired certs: logs error + triggers an immediate async config refresh.
    /// - Certs expiring within 30 days: logs warning + schedules background refresh.
    ///
    /// Non-blocking: always call as `Task { await checkCertExpiry() }`.
    private func checkCertExpiry() async {
        let allAddresses = IceRelaySelector.certificateExpiryAddresses()
        let now = Date()
        let thirtyDaysInterval: TimeInterval = 30 * 24 * 3600
        var expiredAddresses:  [String] = []
        var expiringAddresses: [(address: String, daysLeft: Int)] = []

        for address in allAddresses {
            guard let expiry = IceCertFetcher.certExpiresAtSync(for: address) else { continue }
            let secondsLeft = expiry.timeIntervalSince(now)
            if secondsLeft <= 0 {
                expiredAddresses.append(address)
            } else if secondsLeft < thirtyDaysInterval {
                expiringAddresses.append((address, Int(secondsLeft / 86400)))
            }
        }

        guard !expiredAddresses.isEmpty || !expiringAddresses.isEmpty else { return }

        for addr in expiredAddresses {
            Log.error("🧊 TLS cert EXPIRED on relay \(addr) — fetching fresh config", category: "ICE")
        }
        for (addr, days) in expiringAddresses {
            Log.info("🧊 TLS cert expires in \(days) day(s) on relay \(addr) — scheduling refresh", category: "ICE")
        }

        _ = await IceCertFetcher.shared.fetchAndCacheRelayConfig()
        Log.info("🧊 Cert expiry refresh completed", category: "ICE")
    }

    // MARK: - ICE Mode (tri-state)

    /// The current ICE operation mode. Persists across launches via UserDefaults.
    /// `.off` = no ICE, `.auto` = DPI auto-detect (default iOS), `.on` = always ICE (default macOS).
    @Published var mode: IceMode {
        didSet {
            IceProxyStore.saveMode(mode)
            GRPCChannelManager.shared.updateCachedIceMode(mode)
            Task { await ConnectionLoop.shared.reset() }
            if oldValue != mode {
                stop()
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
        isRunning = false; proxyPort = 0; isWebTunnelActive = false; isOnCooldown = true
        // In .auto mode: clear the "last path = ice" memory so the next startup after cooldown
        // uses standby pre-warm instead of jumping straight to active. Without this, a network
        // change (cellular hand-off, VPN toggle) during cooldown re-enters the
        // handleNetworkPathChange → full ICE start → failure → cooldown loop.
        if mode == .auto { Self.lastSuccessfulPath = nil }
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
        Log.info("🧊 ICE recovery — refreshing cert via .well-known", category: "ICE")
        KeychainManager.shared.deleteIceBridgeCert()
        guard let freshCert = await IceCertFetcher.shared.fetchFromHTTPS() else {
            Log.error("🧊 Failed to fetch fresh ICE cert", category: "ICE")
            return false
        }
        KeychainManager.shared.saveIceBridgeCert(freshCert)
        await fetchConfigAndEvictIfRemoved()
        _ = try? await ConnectionLoop.shared.prepare()
        return true
    }

    /// Rotates to the next available relay without re-fetching the certificate.
    /// Used for inline relay rotation in performRPC when a relay's obfs4 tunnel
    /// is DPI-blocked but the cert itself is still valid.
    /// Returns true if a different relay was started successfully.
    @discardableResult
    private func migrateToModeIfNeeded() {
        if IceProxyStore.needsModeMigration {
            IceProxyStore.markModeMigrationDone()
            if !IceProxyStore.hasStoredMode {
                let migrated = IceMode.migrateFromLegacy()
                mode = migrated
                Log.info("🧊 Migrated to IceMode: \(migrated.rawValue)", category: "ICE")
            }
        }
    }

    /// Start with the stored relay (called at app launch).
    /// In `.on` mode: starts ICE immediately.
    /// Start ICE if mode is .on (always-on). Delegates actual proxy lifecycle to
    /// ConnectionLoop — this method only ensures ICE mode is migrated and stored.
    func startIfEnabled() async {
        migrateToModeIfNeeded()
        guard KeychainManager.shared.isDeviceRegistered() else {
            Log.info("🧊 ICE startup skipped — device not registered", category: "ICE")
            return
        }
        // ConnectionLoop handles proxy lifecycle — just ensure cert is available
        _ = await getIceBridgeCert()
        await fetchConfigAndEvictIfRemoved()
    }

    /// Called on app foreground to verify the ICE proxy process is actually alive.
    /// iOS may kill background threads; `isRunning` may be stale. Restarts if dead.
    func stop() {
        runtime.stop()
        isRunning = false; proxyPort = 0; isWebTunnelActive = false
        activeRelay = nil
    }

    func verifyAliveOrRestart() async {
        _ = try? await ConnectionLoop.shared.prepare()
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
        if isEnabled { Task { try? await ConnectionLoop.shared.prepare() } }

        // Background: refresh relay list now that we're authenticated and can reach AMS.
        Task { await self.fetchConfigAndEvictIfRemoved() }
    }

    /// Fetches the latest relay config from the server and, if the currently active relay
    /// has been deprecated or removed from the manifest, rotates to a live relay immediately.
    ///
    /// This is the replacement for bare `IceCertFetcher.shared.fetchAndCacheRelayList()` calls.
    /// All six post-start background fetches use this so that relay retirement is always handled.
    private func fetchConfigAndEvictIfRemoved() async {
        guard let freshList = await IceCertFetcher.shared.fetchAndCacheRelayConfig() else { return }
        guard let active = activeRelay, let mid = active.manifestId else { return }
        let freshIds   = Set(freshList.map(\.id))
        let deprecated = IceCertFetcher.cachedDeprecatedIdsSync()
        let isRetired  = deprecated.contains(mid) || (!freshIds.isEmpty && !freshIds.contains(mid))
        guard isRetired else { return }
        Log.info("🧊 Active relay \(active.address) [\(mid)] retired by server — rotating", category: "ICE")
        try? await ConnectionLoop.shared.prepare()
    }

    func saveRelay(_ relay: IceRelay) {
        IceProxyStore.saveStoredRelay(relay)
    }

    func loadStoredRelay() -> IceRelay? {
        guard let relay = IceProxyStore.loadStoredRelay() else { return nil }
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
        // Evict if the relay's manifest ID has been deprecated or removed from the server config.
        // This catches the case where a relay is decommissioned between app launches.
        if let mid = relay.manifestId {
            let deprecated = IceCertFetcher.cachedDeprecatedIdsSync()
            let activeIds  = Set((IceCertFetcher.cachedRelayInfosSync() ?? []).map(\.id))
            if deprecated.contains(mid) {
                Log.info("🧊 Cached relay \(relay.address) [\(mid)] is deprecated — evicting", category: "ICE")
                IceProxyStore.clearStoredRelay()
                return nil
            }
            if !activeIds.isEmpty && !activeIds.contains(mid) {
                Log.info("🧊 Cached relay \(relay.address) [\(mid)] removed from server config — evicting", category: "ICE")
                IceProxyStore.clearStoredRelay()
                return nil
            }
        }
        return relay
    }
}
