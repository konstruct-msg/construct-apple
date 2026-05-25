//
//  ConnectionLoop.swift
//  Construct Messenger
//
//  Owns the ICE proxy lifecycle and relay selection for the message stream.
//
//  Replaces the ICE decision logic scattered across MessageStreamManager.connectLoop()
//  and openStream() (IceProxyManager calls, DPI detector, blacklist rotation, cooldown).
//
//  State machine:
//    • directFails < directFailThreshold  →  direct path
//    • directFails >= directFailThreshold →  ICE path (best relay from RelayPool)
//    • network change                     →  reset to direct, stop proxy
//

import Foundation

actor ConnectionLoop {

    // MARK: - Shared instance

    static let shared: ConnectionLoop = {
        let addresses = IceRelaySelector.cachedRelayAddresses()
        let relays = addresses.map { buildRelay(address: $0, bridgeCert: ICEConfig.hardcodedBridgeCert) }
        return ConnectionLoop(relays: relays)
    }()

    // MARK: - State

    private let proxy: IceProxy
    private var pool: RelayPool

    /// Consecutive direct-path failures. Reaching `directFailThreshold` activates ICE.
    private var directFails = 0

    /// ICE activates after this many consecutive direct-path failures.
    private static let directFailThreshold = 2

    /// Consecutive ICE-path stream failures through the current proxy process.
    /// When this reaches `proxyRestartThreshold`, the proxy is force-stopped so the
    /// next `prepare()` starts a fresh process — prevents stale-proxy gen storms.
    private var consecutiveIceFails = 0

    /// Force-restart the ICE proxy after this many consecutive stream failures.
    private static let proxyRestartThreshold = 3

    var shouldUseICE: Bool { directFails >= Self.directFailThreshold }

    // MARK: - Init

    init(relays: [IceRelay], proxy: IceProxy = IceProxy()) {
        self.pool = RelayPool(relays: relays)
        self.proxy = proxy
        if CensoredNetworkDetector.isCensored || IceProxyStore.loadMode() == .on {
            directFails = Self.directFailThreshold
            Log.info("🧊 ConnectionLoop: ICE pre-activated (censored=\(CensoredNetworkDetector.isCensored) mode=\(IceProxyStore.loadMode()))", category: "ICE")
        }
    }

    // MARK: - Prepare

    /// Configures routing for the next `openStream()` attempt.
    ///
    /// Direct path: clears the override port so `GRPCChannelManager` uses direct TLS.
    /// ICE path: starts the proxy for the best available relay and injects the port.
    ///
    /// Returns the ICE proxy port, or `nil` for direct routing.
    @discardableResult
    func prepare() async throws -> UInt16? {
        // In mode=.on ICE is mandatory regardless of directFails. This ensures that after
        // a clean stream end (recordSuccess resets directFails=0), the next attempt still
        // routes through ICE rather than briefly falling through to the direct path.
        let iceRequired = shouldUseICE || IceProxyStore.loadMode() == .on
        guard iceRequired, !pool.isEmpty else {
            GRPCChannelManager.shared.setDirectProxyPort(nil)
            return nil
        }
        guard let relay = pool.best() else {
            GRPCChannelManager.shared.setDirectProxyPort(nil)
            return nil
        }
        do {
            let port = try await proxy.ensure(relay: relay)
            GRPCChannelManager.shared.setDirectProxyPort(port)
            Log.info("🧊 ConnectionLoop: ICE active via \(relay.address) port=\(port)", category: "ICE")
            return port
        } catch {
            pool.recordFailure(relay)
            await proxy.stop()
            GRPCChannelManager.shared.setDirectProxyPort(nil)
            Log.error("🧊 ConnectionLoop: proxy start failed (\(error)) — falling back to direct", category: "ICE")
            throw error
        }
    }

    // MARK: - Feedback

    /// Stream connected successfully — reset failure counters.
    func recordSuccess() async {
        if let relay = await proxy.currentRelay {
            pool.recordSuccess(relay)
        }
        directFails = 0
        consecutiveIceFails = 0
    }

    /// Stream failed — classify and update state accordingly.
    ///
    /// Application-layer errors (auth, validation, etc.) are ignored.
    /// Transport failures on the direct path increment `directFails`.
    /// Transport failures on the ICE path record a relay failure and stop the proxy
    /// when the local proxy itself crashed.
    ///
    /// `invalidatesConnection` should be `false` for background RPCs (OTPK replenishment,
    /// bundle fetch, etc.) whose failure does not indicate relay quality degradation —
    /// the main stream may still be healthy. When false, relay failure counts are not
    /// updated so transient background failures don't cause premature relay rotation.
    func recordFailure(_ error: Error, invalidatesConnection: Bool = true) async {
        guard let reason = IceFailurePolicy.classify(error) else { return }

        if shouldUseICE {
            if let relay = await proxy.currentRelay {
                if !invalidatesConnection {
                    consecutiveIceFails = 0
                    Log.info("🧊 ConnectionLoop: relay failure (\(reason)) on \(relay.address) — skipped (background RPC)", category: "ICE")
                } else if NetworkReachabilityManager.shared.isReachable {
                    if reason == .webTunnelBlocked {
                        // Carrier-level block — add a persistent penalty that survives pool resets
                        // so the relay is deprioritised even after a network path change.
                        pool.recordWebTunnelBlocked(relay)
                        consecutiveIceFails = 0
                    } else {
                        pool.recordFailure(relay)
                        consecutiveIceFails += 1
                        if consecutiveIceFails >= Self.proxyRestartThreshold {
                            Log.info("🧊 ConnectionLoop: \(consecutiveIceFails) consecutive ICE fails — force-restarting proxy", category: "ICE")
                            await proxy.stop()
                            GRPCChannelManager.shared.setDirectProxyPort(nil)
                            consecutiveIceFails = 0
                        }
                    }
                    Log.info("🧊 ConnectionLoop: relay failure (\(reason)) on \(relay.address)", category: "ICE")
                } else {
                    Log.info("🧊 ConnectionLoop: relay failure (\(reason)) ignored — network offline", category: "ICE")
                }
            }
            if reason == .staleLocalProxy {
                await proxy.stop()
                GRPCChannelManager.shared.setDirectProxyPort(nil)
                consecutiveIceFails = 0
            }
        } else {
            directFails += 1
            Log.info("🧊 ConnectionLoop: direct fail \(directFails)/\(Self.directFailThreshold) (\(reason))", category: "ICE")
        }
    }

    // MARK: - Network change

    /// Resets all state on a network path change (cellular↔WiFi, VPN on/off).
    /// The new network may or may not need ICE — restart from scratch.
    func reset() async {
        directFails = (CensoredNetworkDetector.isCensored || IceProxyStore.loadMode() == .on) ? Self.directFailThreshold : 0
        consecutiveIceFails = 0
        pool.resetFailures()
        await proxy.stop()
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        Log.info("🧊 ConnectionLoop: reset (network change)", category: "ICE")
    }

    // MARK: - Relay refresh

    /// Replaces the relay list (e.g., after a manifest fetch from the server).
    /// Preserves per-relay failure counts for addresses that appear in both lists.
    func updateRelays(_ relays: [IceRelay]) async {
        pool = RelayPool(relays: relays)
    }

    // MARK: - Relay building

    /// Builds an `IceRelay` from an address string using the same TLS/WebTunnel detection
    /// logic as `IceProxyManager.makeRelay`, but without the `forceObfs4` override
    /// (IceProxy.start() falls through from WebTunnel to obfs4 automatically on failure).
    private static func buildRelay(address: String, bridgeCert: String) -> IceRelay {
        let resolvedCert = IceCertFetcher.bridgeCertSync(for: address) ?? bridgeCert

        let serverPushedSNI = IceCertFetcher.sniSync(for: address)
        let hardcodedSNI    = ICEConfig.hardcodedRelaySNIs[address]
        let useTLS          = address.hasSuffix(":443")
                           || serverPushedSNI != nil
                           || hardcodedSNI != nil

        let sni: String?
        let pin: String?
        let wtPath: String?
        let wtHostHeader: String?

        if useTLS {
            if let s = serverPushedSNI, !s.isEmpty {
                sni          = s
                pin          = IceCertFetcher.spkiPinSync(for: address)
            } else if let explicitSNI = hardcodedSNI {
                sni          = explicitSNI
                pin          = ICEConfig.hardcodedRelaySPKIs[address]
            } else {
                sni          = address.components(separatedBy: ":").first.flatMap { $0.isEmpty ? nil : $0 }
                pin          = nil
            }
            wtPath       = IceCertFetcher.wtPathSync(for: address)
            wtHostHeader = IceCertFetcher.wtHostHeaderSync(for: address)
        } else {
            sni          = nil
            pin          = nil
            wtPath       = nil
            wtHostHeader = nil
        }

        let iatMode = IceCertFetcher.iatModeSync(for: address) ?? .enabled
        let altSNIs = IceCertFetcher.alternativeSNIsSync(for: address)

        return IceRelay(
            address:         address,
            bridgeCert:      resolvedCert,
            iatMode:         iatMode,
            tlsServerName:   sni,
            pinnedSpki:      pin,
            wtPath:          wtPath,
            wtHostHeader:    wtHostHeader,
            alternativeSNIs: altSNIs,
            manifestId:      nil
        )
    }
}
