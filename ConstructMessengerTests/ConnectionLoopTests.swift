import XCTest
@testable import Construct_Messenger

final class ConnectionLoopTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VeilProxyStore.saveMode(.auto)
        VeilProxyStore.clearStoredRelay()
        VeilProxyStore.lastSuccessfulPath = nil
        WebTunnelPenaltyStore.save([:])
    }

    override func tearDown() {
        VeilProxyStore.saveMode(.auto)
        VeilProxyStore.clearStoredRelay()
        VeilProxyStore.lastSuccessfulPath = nil
        WebTunnelPenaltyStore.save([:])
        super.tearDown()
    }

    func testVeilMode_roundTripsThroughStore() {
        VeilProxyStore.saveMode(.on)
        XCTAssertEqual(VeilProxyStore.loadMode(), .on)

        VeilProxyStore.saveMode(.off)
        XCTAssertEqual(VeilProxyStore.loadMode(), .off)
    }

    func testWebTunnelPenaltyStore_roundTripsValues() {
        let penalty = ["a.test:443": 5, "b.test:443": 11]
        WebTunnelPenaltyStore.save(penalty)
        XCTAssertEqual(WebTunnelPenaltyStore.load(), penalty)
    }

    func testLastSuccessfulPath_canBeSetAndCleared() {
        VeilProxyStore.lastSuccessfulPath = "veil:a.test:443"
        XCTAssertEqual(VeilProxyStore.lastSuccessfulPath, "veil:a.test:443")

        VeilProxyStore.lastSuccessfulPath = nil
        XCTAssertNil(VeilProxyStore.lastSuccessfulPath)
    }

    // MARK: - Reducer: direct-path escalation

    func testTransportReducer_DirectFailureDoesNotEscalateWhenVEILFallbackDisabled() {
        let config = TransportConfig(
            directFailThreshold: 2,
            allowDirectToVeilEscalation: false,
            veilCooldownDuration: 30
        )

        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 1),
            event: .rpcFailed(kind: .transportUnknown, via: .direct(.h2), foreground: true),
            config: config,
            now: Date()
        )

        XCTAssertEqual(outcome.state, .direct(consecutiveFails: 2))
        XCTAssertFalse(outcome.effects.contains(.requestProxyStart))
        XCTAssertFalse(outcome.effects.contains(.invalidateGRPCClient))
    }

    /// With escalation enabled (the default), reaching the threshold flips to VEIL.
    func testTransportReducer_DirectFailureEscalatesAtThreshold() {
        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 1),
            event: .rpcFailed(kind: .transportUnknown, via: .direct(.h2), foreground: true),
            config: .default,
            now: Date()
        )

        XCTAssertEqual(outcome.state, .veilProbing)
        XCTAssertTrue(outcome.effects.contains(.requestProxyStart))
    }

    // MARK: - Reducer: auto mode must try direct first (regression for the
    // censored-region pre-activation that tore down working direct connections).

    func testTransportReducer_AutoOnCensoredNetwork_StartsDirectNotVeil() {
        // A device in a "censored" timezone/region must still begin on direct.
        let initial = TransportState.initial(mode: .auto, censored: true, reachable: true)
        XCTAssertEqual(initial, .direct(consecutiveFails: 0))
    }

    func testTransportReducer_AutoToggleOnCensored_DoesNotForceVeil() {
        // Toggling to .auto on a censored network must NOT force a VEIL probe; it
        // keeps the current (working) direct path and lets failures drive escalation.
        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 0),
            event: .veilModeChanged(.auto, censored: true),
            config: .default,
            now: Date()
        )

        XCTAssertEqual(outcome.state, .direct(consecutiveFails: 0))
        XCTAssertFalse(outcome.effects.contains(.requestProxyStart))
    }

    func testTransportReducer_NetworkPathChange_AutoCensored_DoesNotStartProxy() {
        // A network-path change on a censored network in auto mode recomputes the
        // starting state — it must land on direct without requesting a proxy start.
        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 1),
            event: .networkPathChanged(reachable: true, censored: true, mode: .auto),
            config: .default,
            now: Date()
        )

        XCTAssertEqual(outcome.state, .direct(consecutiveFails: 0))
        XCTAssertFalse(outcome.effects.contains(.requestProxyStart))
    }

    /// Mode `.on` still force-activates VEIL regardless of the censored heuristic.
    func testTransportReducer_ModeOn_ForcesVeilProbing() {
        let initial = TransportState.initial(mode: .on, censored: false, reachable: true)
        XCTAssertEqual(initial, .veilProbing)

        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 0),
            event: .veilModeChanged(.on, censored: false),
            config: .default,
            now: Date()
        )
        XCTAssertEqual(outcome.state, .veilProbing)
        XCTAssertTrue(outcome.effects.contains(.requestProxyStart))
    }

    /// Regression: a proxy that finishes starting AFTER we are on the direct path (e.g. an
    /// obfs4 handshake that was in flight when the user turned VEIL OFF, completing ~200ms
    /// later) must NOT re-activate VEIL. The reducer rejects the stale proxyStarted and tears
    /// the stray proxy down, so OFF stays OFF.
    func testTransportReducer_StaleProxyStartedWhileDirect_DoesNotReactivateVEIL() {
        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 0),
            event: .proxyStarted(relay: "relay.example:443", port: 49262, restarted: false),
            config: .default,
            now: Date()
        )

        XCTAssertEqual(outcome.state, .direct(consecutiveFails: 0))
        XCTAssertTrue(outcome.effects.contains(.requestProxyStop))
        XCTAssertFalse(outcome.effects.contains(.invalidateGRPCClient))
    }

    // MARK: - Router (async, with mock effectors)

    func testTransportRouter_ModeOff_DirectFailuresNeverStartVEIL() async {
        VeilProxyStore.saveMode(.off)

        let proxy = MockProxyEffector()
        let router = TransportRouter(
            config: .default,
            proxyEffector: proxy,
            channelEffector: MockChannelEffector(),
            uiEffector: MockUIEffector()
        )

        await router.send(.networkPathChanged(reachable: true, censored: false, mode: .off))
        await router.send(.rpcFailed(kind: .transportUnknown, via: .direct(.h2), foreground: true))
        await router.send(.rpcFailed(kind: .transportUnknown, via: .direct(.h2), foreground: true))

        let snapshot = await router.snapshot()
        let proxyStartCalls = await proxy.startCalls()
        XCTAssertEqual(snapshot.state, .direct(consecutiveFails: 2))
        XCTAssertEqual(proxyStartCalls, 0)
    }

    func testTransportRouter_AutoCensored_StaysDirectUntilRealFailure() async {
        VeilProxyStore.saveMode(.auto)

        let proxy = MockProxyEffector()
        let router = TransportRouter(
            config: .default,
            proxyEffector: proxy,
            channelEffector: MockChannelEffector(),
            uiEffector: MockUIEffector()
        )

        // Censored network, auto mode: must begin on direct and stay there while the
        // direct path is healthy / only blips once (below the escalation threshold).
        await router.send(.networkPathChanged(reachable: true, censored: true, mode: .auto))
        await router.send(.rpcFailed(kind: .transportUnknown, via: .direct(.h2), foreground: true))

        let snapshot = await router.snapshot()
        let proxyStartCalls = await proxy.startCalls()
        XCTAssertEqual(snapshot.state, .direct(consecutiveFails: 1))
        XCTAssertEqual(proxyStartCalls, 0)
    }
}

private actor MockProxyEffector: ProxyEffector {
    private var starts = 0

    func start() async -> TransportEvent {
        starts += 1
        return .proxyStartFailed(relay: nil, reason: "unexpected")
    }

    func stop() async {}
    func updateRelays(_ relays: [VeilRelay]) async { _ = relays }
    func startCalls() -> Int { starts }
}

private actor MockChannelEffector: ChannelEffector {
    func invalidateClient() async {}
    func setVeilPort(_ port: UInt16?) async { _ = port }
}

private actor MockUIEffector: UIEffector {
    func publish(state: TransportState, event: TransportEvent, transition: TransitionLogEntry) async {
        _ = state
        _ = event
        _ = transition
    }
}
