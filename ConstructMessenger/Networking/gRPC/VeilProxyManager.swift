//
//  VeilProxyManager.swift
//  Construct Messenger
//
//  Manages the local obfs4 proxy (construct-veil / VEIL).
//
//  Architecture:
//    [Swift gRPC] → 127.0.0.1:proxyPort (plain TCP, no TLS)
//        → [Rust proxy] → Obfs4Stream → relay:443 (obfuscated)
//        → [relay VPS] → main Construct server
//
//  The proxy lives entirely inside libconstruct_core.a. All C FFI calls are routed
//  through VeilProxy (actor) → VeilProxyRuntime → NativeVeilRuntime.
//  GRPCChannelManager checks isRunning and switches targets automatically.
//

import Foundation
import Combine

/// Manages the construct-veil local TCP proxy for gRPC obfuscation.
@MainActor
final class VeilProxyManager: ObservableObject {

    static let shared = VeilProxyManager()

    private init() {
        // Load persisted mode (or platform default if never set).
        self.mode = VeilProxyStore.loadMode()

        // Restart the VEIL proxy whenever the network interface changes.
        // After a cellular ↔ WiFi switch the old TCP tunnel to the relay is dead;
        // the Rust proxy process is still "running" but silently broken.
        // We restart proactively so the next RPC finds a healthy proxy immediately.
        // TransportRouter handles the actual proxy lifecycle on path change; we only
        // mirror the local UI state (stop publishes isRunning=false).
        NotificationCenter.default.addObserver(
            forName: .networkPathChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.stop()
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var isRunning = false {
        didSet {
            // Notify ConnectionStatusManager so it can proactively degrade status
            // when the VEIL proxy dies while the stream hasn't noticed yet.
            NotificationCenter.default.post(
                name: .veilProxyStateChanged,
                object: nil,
                userInfo: ["isRunning": isRunning]
            )
        }
    }
    @Published private(set) var proxyPort: UInt16 = 0
    @Published private(set) var activeRelay: VeilRelay?
    @Published private(set) var lastError: String?
    /// True when the active transport is WebTunnel (VEIL v2) rather than obfs4.
    @Published private(set) var isWebTunnelActive: Bool = false
    /// True while VEIL is in cooldown after a relay failure. Drives the UI directly —
    /// changes to this property cause the Network settings view to re-render.
    @Published private(set) var isOnCooldown: Bool = false

    // MARK: - Persisted path memory

    /// Persists which path successfully handled gRPC traffic last session.
    /// Used in `.auto` mode to choose initial routing on launch.
    static var lastSuccessfulPath: String? {
        get { VeilProxyStore.lastSuccessfulPath }
        set { VeilProxyStore.lastSuccessfulPath = newValue }
    }

    /// Persisted quality scores for known relays. Loaded from UserDefaults at init;
    /// updated and saved after every success/failure RPC through VEIL.
    var isCurrentRelayVerified: Bool {
        get async {
            let snapshot = await TransportRouter.shared.snapshot()
            if case .veilActive = snapshot.state { return true }
            return false
        }
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

    /// Record a successful RPC through VEIL. Updates the session-verified set and the
    /// persisted quality score. Triggers side effects on the first success of the session.
    func recordRelaySuccess(address: String, latency: TimeInterval) {
        Task {
            await TransportRouter.shared.send(
                .rpcSucceeded(via: .veil(port: 0, relay: address), latencyMs: Int(latency * 1000))
            )
        }
        // VEIL is confirmed working — ensure / renew capabilities in-band
        // (each step no-ops unless needed; rate-limited internally).
        VeilCapabilityProvisioner.shared.provisionIfNeeded(relayAddress: address)
        VeilCapabilityRenewer.shared.renewIfNeeded(relayAddress: address)
        // Ticket B1: bootstrap/renew the key-bound capability over the same live
        // tunnel (no-ops unless needed; rate-limited internally).
        VeilCapabilityV2Bootstrapper.shared.bootstrapOrRenewIfNeeded(relayAddress: address)
    }


    // MARK: - Cert expiry monitoring

    /// Checks TLS certificate expiry for all known relays from the server-pushed config.
    /// - Expired certs: logs error + triggers an immediate async config refresh.
    /// - Certs expiring within 30 days: logs warning + schedules background refresh.
    ///
    /// Non-blocking: always call as `Task { await checkCertExpiry() }`.
    private func checkCertExpiry() async {
        let allAddresses = VeilRelaySelector.certificateExpiryAddresses()
        let now = Date()
        let thirtyDaysInterval: TimeInterval = 30 * 24 * 3600
        var expiredAddresses:  [String] = []
        var expiringAddresses: [(address: String, daysLeft: Int)] = []

        for address in allAddresses {
            guard let expiry = VeilCertFetcher.certExpiresAtSync(for: address) else { continue }
            let secondsLeft = expiry.timeIntervalSince(now)
            if secondsLeft <= 0 {
                expiredAddresses.append(address)
            } else if secondsLeft < thirtyDaysInterval {
                expiringAddresses.append((address, Int(secondsLeft / 86400)))
            }
        }

        guard !expiredAddresses.isEmpty || !expiringAddresses.isEmpty else { return }

        for addr in expiredAddresses {
            Log.error("TLS cert EXPIRED on relay \(addr) — fetching fresh config", category: "VEIL")
        }
        for (addr, days) in expiringAddresses {
            Log.info("TLS cert expires in \(days) day(s) on relay \(addr) — scheduling refresh", category: "VEIL")
        }

        _ = await VeilCertFetcher.shared.fetchAndCacheRelayConfig()
        Log.info("Cert expiry refresh completed", category: "VEIL")
    }

    // MARK: - VEIL Mode (tri-state)

    /// The current VEIL operation mode. Persists across launches via UserDefaults.
    /// `.off` = no VEIL, `.auto` = DPI auto-detect (default iOS), `.on` = always VEIL (default macOS).
    @Published var mode: VeilMode {
        didSet {
            VeilProxyStore.saveMode(mode)
            Task {
                let censored = CensoredNetworkDetector.isCensored
                await TransportRouter.shared.send(.veilModeChanged(mode, censored: censored))
            }
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
        if isOnCooldown { return .veilCooldown }
        guard isRunning, let relay = activeRelay else {
            if isEnabled { return .veilConnecting }
            return .direct
        }
        if isWebTunnelActive { return .veilWebTunnel(relay: relay.address) }
        // iOS uses veil-front (honest-front HTTPS); obfs4/WebTunnel are retired.
        return .veilFront(relay: relay.address)
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
        if let stored = KeychainManager.shared.loadVEILBridgeCert(), !stored.isEmpty {
            return stored
        }
        // obfs4 is retired — no hardcoded bridge cert. Empty bridge line is harmless
        // since obfs4 is excluded from the probe race.
        return ""
    }

    /// Rotates to the next available relay without re-fetching the certificate.
    /// Used for inline relay rotation in performRPC when a relay's obfs4 tunnel
    /// is DPI-blocked but the cert itself is still valid.
    /// Returns true if a different relay was started successfully.
    private func migrateToModeIfNeeded() {
        if VeilProxyStore.needsModeMigration {
            VeilProxyStore.markModeMigrationDone()
            if !VeilProxyStore.hasStoredMode {
                let migrated = VeilMode.migrateFromLegacy()
                mode = migrated
                Log.info("Migrated to VeilMode: \(migrated.rawValue)", category: "VEIL")
            }
        }
    }

    /// User-facing enable path for `.auto` / `.on`.
    ///
    /// Always pulls the latest signed relay config (addresses + cert material) from the
    /// server first — silent, no UI surface for coordinates — then starts the proxy if
    /// the current mode actually needs VEIL. Failures fall back to cache / seed relays.
    ///
    /// - `.on`: fetches config, then forces a VEIL probe via the transport router.
    /// - `.auto`: fetches config so the pool is warm; only starts the proxy when the
    ///   transport layer already prefers VEIL (direct path is blocked).
    func refreshConfigAndStartIfNeeded() async {
        migrateToModeIfNeeded()
        guard mode != .off else {
            Log.info("VEIL enable skipped — mode is off", category: "VEIL")
            return
        }
        guard KeychainManager.shared.isDeviceRegistered() else {
            Log.info("VEIL enable skipped — device not registered", category: "VEIL")
            return
        }

        Log.info("VEIL enable — refreshing server relay config (mode=\(mode.rawValue))", category: "VEIL")
        // Pull addresses + SPKI/SNI/cert material from the signed well-known manifest.
        // Seeds remain the floor if the fetch fails (censored first hop, offline, etc.).
        await fetchConfigAndEvictIfRemoved()

        // Capability pipeline over whatever transport is up (typically direct right
        // after the user toggles). First-issue is the critical path when no ticket
        // was ever imported; renew/B1 no-op unless needed.
        ensureCapabilitiesForPrimaryRelay()

        await startIfNeeded()
    }

    /// Start or refresh VEIL when the transport layer actually needs it.
    /// In `.auto` mode the *proxy* is a no-op on a healthy direct path — but we still
    /// auto-provision / renew the veil-front capability over direct so the client has
    /// a working ticket ready before the network becomes censored.
    func startIfNeeded() async {
        migrateToModeIfNeeded()
        guard mode != .off else {
            Log.info("VEIL startup skipped — mode is off", category: "VEIL")
            return
        }
        guard KeychainManager.shared.isDeviceRegistered() else {
            Log.info("VEIL startup skipped — device not registered", category: "VEIL")
            return
        }

        // ALWAYS run capability ensure on a registered device with VEIL not off —
        // including auto+direct. First-issue over clearnet is how we remove the
        // manual QR/paste dependency for normal logins. Rate-limited internally.
        ensureCapabilitiesForPrimaryRelay()

        if mode == .auto {
            let snap = await TransportRouter.shared.snapshot()
            guard snap.state.prefersVEIL else {
                Log.debug("VEIL proxy startup skipped — auto mode on direct path (capability ensure still ran)", category: "VEIL")
                return
            }
        }

        // EntryDirectory Source 3: VEIL is genuinely active now. In the censored/island
        // regime, browse the LAN for domestic island relays (this is the only place that
        // raises the local-network prompt — never at launch). Off-regime: no-op.
        startLocalDiscoveryIfCensored()
        // ConnectionLoop handles proxy lifecycle. iOS is veil-front-only (SPKI pin +
        // per-user ticket); the obfs4 bridge cert is not used, so we no longer fetch it
        // here — that fetch only added two 8s .well-known/ice-cert timeouts on censored
        // networks. The relay manifest is still refreshed for AMS relay retirement.
        await fetchConfigAndEvictIfRemoved()
    }

    /// First-issue (if missing) → near-expiry renew → B1 bootstrap/renew for the
    /// primary seed relay. Safe to call often; each step is rate-limited + no-ops when idle.
    private func ensureCapabilitiesForPrimaryRelay() {
        let address = VEILConfig.ruRelayAddress
        VeilCapabilityProvisioner.shared.provisionIfNeeded(relayAddress: address)
        VeilCapabilityRenewer.shared.renewIfNeeded(relayAddress: address)
        VeilCapabilityV2Bootstrapper.shared.bootstrapOrRenewIfNeeded(relayAddress: address)
    }

    /// Legacy name — forwards to `startIfNeeded()`.
    func startIfEnabled() async {
        await startIfNeeded()
    }

    /// Called on app foreground to verify the VEIL proxy process is actually alive.
    /// iOS may kill background threads; `isRunning` may be stale. Restarts if dead.
    func stop() {
        isRunning = false; proxyPort = 0; isWebTunnelActive = false
        activeRelay = nil
        // Tear down Source 3 discovery when VEIL is torn down: discovered relays are only
        // valid on the current LAN, and browsing costs battery + keeps the local-net prompt live.
        VeilLocalDiscovery.shared.stop()
    }

    // MARK: - EntryDirectory Source 3 (local discovery)

    /// Begin browsing the LAN for domestic island relays, but only in the censored/island
    /// regime — off-regime it stays dark so we never raise the local-network prompt or spend
    /// battery where local relays cannot exist. Idempotent (VeilLocalDiscovery.start guards).
    private func startLocalDiscoveryIfCensored() {
        guard CensoredNetworkDetector.isCensored else { return }
        VeilLocalDiscovery.shared.onDiscoveredRelaysChanged = { [weak self] in
            Task { @MainActor in await self?.refreshRelayPoolFromDiscovery() }
        }
        VeilLocalDiscovery.shared.start()
    }

    /// Re-snapshot the relay pool (now including any LAN-discovered relays) and push it into
    /// the router's proxy pool so the next probe race can pick a discovered island relay.
    private func refreshRelayPoolFromDiscovery() async {
        let freshRelays = ConnectionLoopRelayBridge.snapshotRelays()
        await TransportRouter.shared.updateRelays(freshRelays)
    }

    /// Foreground hook: the TransportRouter FSM detects stale proxies via the next failed RPC
    /// (which classifies as `.staleLocalProxy` → rotates). Kept as a no-op for callers that
    /// still invoke it; once removed in Chunk 4 this method goes away entirely.
    func verifyAliveOrRestart() async {
        // intentional no-op
    }

    // MARK: - Server-provided configuration

    /// Called after login/register/recovery with the cert from `AuthTokensResponse`.
    /// Saves the cert, refreshes the relay list, and starts the proxy if VEIL is enabled.
    func configureFromServer(cert: String) {
        guard !cert.isEmpty else { return }
        KeychainManager.shared.saveVEILBridgeCert(cert)
        let host = GRPCChannelManager.shared.currentHost
        let veilHost = "ice.\(host)"
        let relay = VeilRelay(
            address: "\(veilHost):443",
            bridgeCert: cert,
            iatMode: .enabled,
            tlsServerName: veilHost
        )
        saveRelay(relay)
        if isEnabled { Task { await TransportRouter.shared.send(.veilConfigChanged) } }

        // Background: refresh relay list now that we're authenticated and can reach AMS.
        Task { await self.fetchConfigAndEvictIfRemoved() }
    }

    /// Fetches the latest relay config from the server and, if the currently active relay
    /// has been deprecated or removed from the manifest, rotates to a live relay immediately.
    ///
    /// This is the replacement for bare `VeilCertFetcher.shared.fetchAndCacheRelayList()` calls.
    /// All six post-start background fetches use this so that relay retirement is always handled.
    private func fetchConfigAndEvictIfRemoved() async {
        guard let freshList = await VeilCertFetcher.shared.fetchAndCacheRelayConfig() else { return }
        // Always push the fresh manifest into the router's proxy pool so subsequent probes pick it up.
        let freshRelays = ConnectionLoopRelayBridge.snapshotRelays()
        await TransportRouter.shared.updateRelays(freshRelays)
        guard let active = activeRelay, let mid = active.manifestId else { return }
        let freshIds   = Set(freshList.map(\.id))
        let deprecated = VeilCertFetcher.cachedDeprecatedIdsSync()
        let isRetired  = deprecated.contains(mid) || (!freshIds.isEmpty && !freshIds.contains(mid))
        guard isRetired else { return }
        Log.info("Active relay \(active.address) [\(mid)] retired by server — rotating", category: "VEIL")
        await TransportRouter.shared.send(.veilConfigChanged)
    }

    func saveRelay(_ relay: VeilRelay) {
        VeilProxyStore.saveStoredRelay(relay)
    }

    /// Called by ConnectionLoop to keep published state in sync with the actual proxy.
    func updateVEILProxyState(isRunning: Bool, port: UInt16, relay: VeilRelay?, isWebTunnel: Bool) {
        self.isRunning = isRunning
        self.proxyPort = port
        self.activeRelay = relay
        self.isWebTunnelActive = isWebTunnel
    }

    /// Record the most recent proxy-start failure reason (from `veil_last_error`,
    /// e.g. "veil-front: timeout after 7003ms"), shown in Network settings while
    /// VEIL is enabled but not yet running. Pass `nil` on a successful start.
    func reportLastError(_ reason: String?) {
        lastError = reason
    }
}
