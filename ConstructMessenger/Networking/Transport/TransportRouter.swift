//
//  TransportRouter.swift
//  Construct Messenger
//
//  Single owner of transport-layer state.
//
//  The router is an actor that runs the FSM and applies effects through pluggable
//  effectors. All transport routing decisions in the app flow through `send(_:)`.
//  No singleton outside this file mutates routing state — only the router does.
//
//  The reducer is pure (see `TransportReducer.swift`). This file contains only the
//  glue: dispatch, effect application, cooldown timer, and transition logging.
//

import Foundation

actor TransportRouter {

    // MARK: - Shared instance

    /// Process-wide router. Constructed lazily so initial-state inputs (VEIL mode,
    /// censored region, reachability) are read at first access, not at module load.
    static let shared: TransportRouter = TransportRouter.makeDefault()

    /// Factory used by `shared` — broken out so tests can construct routers with mock effectors.
    private static func makeDefault() -> TransportRouter {
        let initialRelays = ConnectionLoopRelayBridge.snapshotRelays()
        let blockedPenalty = WebTunnelPenaltyStore.load()
        return TransportRouter(
            config: .default,
            proxyEffector: NativeProxyEffector(initialRelays: initialRelays, blockedPenalty: blockedPenalty),
            channelEffector: GRPCChannelEffector(),
            uiEffector: ConnectionStatusEffector()
        )
    }

    // MARK: - Dependencies

    private let proxyEffector: any ProxyEffector
    private let channelEffector: any ChannelEffector
    private let uiEffector: any UIEffector

    // MARK: - State

    private var config: TransportConfig
    private var currentMode: VeilMode
    private(set) var state: TransportState
    private var transitionLog: [TransitionLogEntry] = []
    private let transitionLogCapacity = 200
    private var cooldownTask: Task<Void, Never>?

    // MARK: - Init

    init(
        config: TransportConfig = .default,
        proxyEffector: any ProxyEffector,
        channelEffector: any ChannelEffector,
        uiEffector: any UIEffector
    ) {
        self.config = config
        self.proxyEffector = proxyEffector
        self.channelEffector = channelEffector
        self.uiEffector = uiEffector
        let mode = VeilProxyStore.loadMode()
        self.currentMode = mode
        let censored = CensoredNetworkDetector.isCensored
        let reachable = NetworkReachabilityManager.shared.isReachable
        self.state = .initial(mode: mode, censored: censored, reachable: reachable)
        Log.info("TransportRouter init → \(state.shortLabel) (mode=\(mode), censored=\(censored), reachable=\(reachable))", category: "Transport")
    }

    // MARK: - Public API

    /// The single entry point for all external interactions. Posts an event into the FSM;
    /// the resulting state transition and effects are applied serially before returning.
    func send(_ event: TransportEvent) async {
        let now = Date()
        let modeForEvent = resolvedMode(for: event)
        currentMode = modeForEvent
        let outcome = TransportReducer.reduce(
            state: state,
            event: event,
            config: effectiveConfig(for: modeForEvent),
            now: now
        )
        let oldState = state
        state = outcome.state

        let entry = TransitionLogEntry(
            at: now,
            from: oldState,
            to: outcome.state,
            event: event.shortLabel,
            cause: "",
            effects: outcome.effects.map(\.shortLabel)
        )
        appendToLog(entry)
        Log.info("Transport: \(entry.oneLine)", category: "Transport")
        await uiEffector.publish(state: outcome.state, event: event, transition: entry)

        // Apply the synchronous effects first so the channel reflects the new state
        // before any external observer (e.g. the next RPC) reads it.
        await applySync(outcome.effects)

        // Asynchronous follow-ups. A proxy-start request triggers an async dance with
        // the proxy effector; we feed the outcome back into the router via `send`.
        if outcome.effects.contains(.requestProxyStart) {
            let outcomeEvent = await proxyEffector.start()
            await send(outcomeEvent)
        }
    }

    /// Kick the FSM into action after init. Should be called once at app startup,
    /// after reachability + VEIL-mode singletons are usable. Idempotent — calling
    /// it on an already-active router is a no-op.
    func bootstrap() async {
        Log.info("Transport: bootstrap (state=\(state.shortLabel))", category: "Transport")
        if case .veilProbing = state {
            // Reducer.initial(...) put us in probing; fire the initial proxy start.
            let outcome = await proxyEffector.start()
            await send(outcome)
        }
    }

    /// Snapshot of the current state and recent transitions for diagnostics / support.
    func snapshot() -> (state: TransportState, log: [TransitionLogEntry], config: TransportConfig) {
        (state, transitionLog, config)
    }

    /// Override config (e.g. from a debug screen or a test).
    func setConfig(_ new: TransportConfig) {
        config = new
        Log.info("Transport: config updated", category: "Transport")
    }

    /// Replace the relay candidate set used by the proxy effector. Called after
    /// a successful relay manifest fetch from the server.
    func updateRelays(_ relays: [VeilRelay]) async {
        await proxyEffector.updateRelays(relays)
    }

    // MARK: - Effect application

    private func applySync(_ effects: [TransportEffect]) async {
        for effect in effects {
            switch effect {
            case .invalidateGRPCClient:
                await channelEffector.invalidateClient()

            case .setVeilPort(let port):
                await channelEffector.setVeilPort(port)

            case .requestProxyStop:
                cancelCooldownTimer()
                await proxyEffector.stop()

            case .scheduleCooldownEnd(let date):
                scheduleCooldown(at: date)

            case .requestProxyStart:
                // Handled as an async follow-up in `send`.
                break
            }
        }
    }

    // MARK: - Cooldown timer

    private func scheduleCooldown(at date: Date) {
        cancelCooldownTimer()
        let interval = max(0, date.timeIntervalSinceNow)
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            await self?.send(.cooldownElapsed)
        }
    }

    private func cancelCooldownTimer() {
        cooldownTask?.cancel()
        cooldownTask = nil
    }

    // MARK: - Transition log

    private func appendToLog(_ entry: TransitionLogEntry) {
        transitionLog.append(entry)
        if transitionLog.count > transitionLogCapacity {
            transitionLog.removeFirst(transitionLog.count - transitionLogCapacity)
        }
    }

    private func resolvedMode(for event: TransportEvent) -> VeilMode {
        switch event {
        case .veilModeChanged(let mode, _):
            return mode
        case .networkPathChanged(_, _, let mode):
            return mode
        default:
            return currentMode
        }
    }

    private func effectiveConfig(for mode: VeilMode) -> TransportConfig {
        var effective = config
        effective.allowDirectToVeilEscalation = mode != .off
        return effective
    }
}

// MARK: - Bridge for initial relay snapshot

/// Reads the same relay-candidate set that `ConnectionLoop.shared` used to build at init,
/// without keeping a dependency on `ConnectionLoop`. Lives here so the router boot path
/// has a single, obvious place to look for it.
enum ConnectionLoopRelayBridge {
    static func snapshotRelays() -> [VeilRelay] {
        let addresses = VeilRelaySelector.cachedRelayAddresses()
        return addresses.map { buildRelay(address: $0, bridgeCert: VEILConfig.hardcodedBridgeCert) }
    }

    /// Copy of `ConnectionLoop.buildRelay` — kept here so the router boot path is
    /// independent of ConnectionLoop. Once ConnectionLoop is deleted in Chunk 3 this
    /// becomes the canonical implementation.
    private static func buildRelay(address: String, bridgeCert: String) -> VeilRelay {
        let resolvedCert = VeilCertFetcher.bridgeCertSync(for: address) ?? bridgeCert
        let serverPushedSNI = VeilCertFetcher.sniSync(for: address)
        let hardcodedSNI    = VEILConfig.hardcodedRelaySNIs[address]
        let useTLS          = address.hasSuffix(":443")
                           || serverPushedSNI != nil
                           || hardcodedSNI != nil

        let sni: String?
        let pin: String?
        let wtPath: String?
        let wtHostHeader: String?

        if useTLS {
            // A binary-pinned relay's SPKI is the source of truth. `sniSync` falls back
            // to the hardcoded SNI, so `serverPushedSNI` is non-nil for every relay we
            // ship an SNI for — which made the cached-manifest pin (spkiPinSync) win
            // unconditionally and the hardcoded pin below dead code. A stale cached
            // manifest then handed `veil_start` a wrong SPKI → the relay's real cert
            // failed the pin check → `HandshakeFailure`. It is also a downgrade vector:
            // the untrusted server manifest must never override a pin baked into the
            // binary. So the hardcoded pin always wins; the manifest pin is only used
            // for relays we do not pin ourselves.
            let hardcodedPin = VEILConfig.hardcodedRelaySPKIs[address]
            if let s = serverPushedSNI, !s.isEmpty {
                sni = s
                pin = hardcodedPin ?? VeilCertFetcher.spkiPinSync(for: address)
            } else if let explicitSNI = hardcodedSNI {
                sni = explicitSNI
                pin = hardcodedPin
            } else {
                sni = address.components(separatedBy: ":").first.flatMap { $0.isEmpty ? nil : $0 }
                pin = nil
            }
            wtPath = VeilCertFetcher.wtPathSync(for: address)
            wtHostHeader = VeilCertFetcher.wtHostHeaderSync(for: address)
        } else {
            sni = nil; pin = nil; wtPath = nil; wtHostHeader = nil
        }

        let iatMode = VeilCertFetcher.iatModeSync(for: address) ?? .enabled
        let altSNIs = VeilCertFetcher.alternativeSNIsSync(for: address)

        return VeilRelay(
            address: address,
            bridgeCert: resolvedCert,
            iatMode: iatMode,
            tlsServerName: sni,
            pinnedSpki: pin,
            wtPath: wtPath,
            wtHostHeader: wtHostHeader,
            alternativeSNIs: altSNIs,
            manifestId: nil,
            // Per-user ticket imported out-of-band (signed config blob → Keychain);
            // never hardcoded in the binary. nil → coordinator excludes veil-front.
            veilFrontTicket: VeilTicketStore.ticket(for: address)
        )
    }
}
