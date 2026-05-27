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
//  The proxy lives entirely inside libconstruct_core.a. All C FFI calls are routed
//  through IceProxy (actor) → IceProxyRuntime → NativeIceProxyRuntime.
//  GRPCChannelManager checks isRunning and switches targets automatically.
//

import Foundation
import Combine

/// Manages the construct-ice local TCP proxy for gRPC obfuscation.
@MainActor
final class IceProxyManager: ObservableObject {

    static let shared = IceProxyManager()

    private init() {
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
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.stop()
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
            Log.error("TLS cert EXPIRED on relay \(addr) — fetching fresh config", category: "ICE")
        }
        for (addr, days) in expiringAddresses {
            Log.info("TLS cert expires in \(days) day(s) on relay \(addr) — scheduling refresh", category: "ICE")
        }

        _ = await IceCertFetcher.shared.fetchAndCacheRelayConfig()
        Log.info("Cert expiry refresh completed", category: "ICE")
    }

    // MARK: - ICE Mode (tri-state)

    /// The current ICE operation mode. Persists across launches via UserDefaults.
    /// `.off` = no ICE, `.auto` = DPI auto-detect (default iOS), `.on` = always ICE (default macOS).
    @Published var mode: IceMode {
        didSet {
            IceProxyStore.saveMode(mode)
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

    func clearCooldown() {
        isOnCooldown = false
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
        Log.info("Using hardcoded ICE bridge cert (last resort)", category: "ICE")
        return ICEConfig.hardcodedBridgeCert
    }

    /// Called when ICE handshake fails repeatedly (stale cert or SPKI after server key rotation).
    /// Clears Keychain cache, fetches fresh obfs4 cert AND relay TLS config (SPKI pins) from .well-known,
    /// unblacklists any relay whose config was refreshed, then restarts proxy via fallback chain.
    /// Returns true if a new cert was obtained and proxy was restarted successfully.
    @discardableResult
    func refreshCertAndRestart() async -> Bool {
        Log.info("ICE recovery — refreshing cert via .well-known", category: "ICE")
        KeychainManager.shared.deleteIceBridgeCert()
        guard let freshCert = await IceCertFetcher.shared.fetchFromHTTPS() else {
            Log.error("Failed to fetch fresh ICE cert", category: "ICE")
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
    private func migrateToModeIfNeeded() {
        if IceProxyStore.needsModeMigration {
            IceProxyStore.markModeMigrationDone()
            if !IceProxyStore.hasStoredMode {
                let migrated = IceMode.migrateFromLegacy()
                mode = migrated
                Log.info("Migrated to IceMode: \(migrated.rawValue)", category: "ICE")
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
            Log.info("ICE startup skipped — device not registered", category: "ICE")
            return
        }
        // ConnectionLoop handles proxy lifecycle — just ensure cert is available
        _ = await getIceBridgeCert()
        await fetchConfigAndEvictIfRemoved()
    }

    /// Called on app foreground to verify the ICE proxy process is actually alive.
    /// iOS may kill background threads; `isRunning` may be stale. Restarts if dead.
    func stop() {
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
        Log.info("Active relay \(active.address) [\(mid)] retired by server — rotating", category: "ICE")
        _ = try? await ConnectionLoop.shared.prepare()
    }

    func saveRelay(_ relay: IceRelay) {
        IceProxyStore.saveStoredRelay(relay)
    }

    /// Called by ConnectionLoop to keep published state in sync with the actual proxy.
    func updateICEProxyState(isRunning: Bool, port: UInt16, relay: IceRelay?, isWebTunnel: Bool) {
        self.isRunning = isRunning
        self.proxyPort = port
        self.activeRelay = relay
        self.isWebTunnelActive = isWebTunnel
    }
}
