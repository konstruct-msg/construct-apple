import XCTest
import GRPCCore   // RPCError — the input `mapStreamFailureKind` classifies
@testable import Construct_Messenger

final class ConnectionLoopTests: XCTestCase {

    /// Polls until the router settles in `.veilActive`. Needed because `requestProxyStart`
    /// is applied as an async follow-up off the router actor, so `send` returns before the
    /// proxy has reported back. Returns false on timeout so the caller can fail loudly
    /// instead of asserting against a half-applied transition.
    private func waitForVeilActive(_ router: TransportRouter, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .veilActive = await router.snapshot().state { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

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

    func testTransportRouter_AutoDeescalatesWhenDirectSucceedsUnderVEIL() async {
        VeilProxyStore.saveMode(.auto)

        let proxy = MockProxyEffector(startEvent: .proxyStarted(relay: "relay.example:443", port: 49262, restarted: false))
        let router = TransportRouter(
            config: .default,
            proxyEffector: proxy,
            channelEffector: MockChannelEffector(),
            uiEffector: MockUIEffector()
        )

        await router.send(.rpcFailed(kind: .transportUnknown, via: .direct(.h2), foreground: true))
        await router.send(.rpcFailed(kind: .transportUnknown, via: .direct(.h2), foreground: true))

        // Proxy start is an async follow-up off the router actor (6e86300a — the FSM must
        // stay responsive during a probe), so `send` returns while the state is still
        // .veilProbing. De-escalation is guarded on .veilActive, so the success has to
        // arrive after proxyStarted lands — which is also the real ordering on device.
        let reachedActive = await waitForVeilActive(router)
        XCTAssertTrue(reachedActive, "Router never reached .veilActive — proxy start did not land")

        await router.send(.rpcSucceeded(via: .direct(.h2), latencyMs: 50))

        let snapshot = await router.snapshot()
        XCTAssertEqual(snapshot.state, .direct(consecutiveFails: 0))
        let stopCalls = await proxy.stopCalls()
        XCTAssertEqual(stopCalls, 1)
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

    // MARK: - Stream (data plane) events — transport-connection-health-and-escalation

    /// QUIC mid-session death must count like a direct transport failure (router must
    /// not stay blind — regression for "not reported to router — experimental H3/QUIC").
    func testTransportReducer_StreamFailedQuic_CountsTowardDirectFails() {
        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 0),
            event: .streamFailed(
                method: .quic,
                kind: .midSessionTimeout,
                via: .direct(.h3)
            ),
            config: .default,
            now: Date()
        )
        XCTAssertEqual(outcome.state, .direct(consecutiveFails: 1))
        XCTAssertFalse(outcome.effects.contains(.requestProxyStart))
    }

    /// Two stream failures on direct escalate to VEIL when allowed (same threshold as rpcFailed).
    func testTransportReducer_StreamFailedTwice_EscalatesToVeilProbing() {
        let first = TransportReducer.reduce(
            state: .direct(consecutiveFails: 0),
            event: .streamFailed(method: .quic, kind: .midSessionTimeout, via: .direct(.h3)),
            config: .default,
            now: Date()
        )
        XCTAssertEqual(first.state, .direct(consecutiveFails: 1))

        let second = TransportReducer.reduce(
            state: first.state,
            event: .streamFailed(method: .h2, kind: .openTimeout, via: .direct(.h2)),
            config: .default,
            now: Date()
        )
        XCTAssertEqual(second.state, .veilProbing)
        XCTAssertTrue(second.effects.contains(.requestProxyStart))
    }

    /// mode=off must not escalate on stream failures either.
    func testTransportReducer_StreamFailed_DoesNotEscalateWhenVEILFallbackDisabled() {
        let config = TransportConfig(
            directFailThreshold: 2,
            allowDirectToVeilEscalation: false,
            veilCooldownDuration: 30
        )
        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 1),
            event: .streamFailed(method: .h2, kind: .openTimeout, via: .direct(.h2)),
            config: config,
            now: Date()
        )
        XCTAssertEqual(outcome.state, .direct(consecutiveFails: 2))
        XCTAssertFalse(outcome.effects.contains(.requestProxyStart))
    }

    /// Successful stream open clears the fail streak (data plane recovered).
    func testTransportReducer_StreamOpened_ResetsDirectFails() {
        let outcome = TransportReducer.reduce(
            state: .direct(consecutiveFails: 2),
            event: .streamOpened(method: .quic, via: .direct(.h3)),
            config: .default,
            now: Date()
        )
        XCTAssertEqual(outcome.state, .direct(consecutiveFails: 0))
    }

    /// Auto + censored still starts direct; stream failure is what escalates (not geography).
    func testTransportReducer_AutoCensored_StreamFailsEscalateNotGeography() {
        let initial = TransportState.initial(mode: .auto, censored: true, reachable: true)
        XCTAssertEqual(initial, .direct(consecutiveFails: 0))

        var state = initial
        for _ in 0..<2 {
            let o = TransportReducer.reduce(
                state: state,
                event: .streamFailed(method: .quic, kind: .midSessionTimeout, via: .direct(.h3)),
                config: .default,
                now: Date()
            )
            state = o.state
        }
        XCTAssertEqual(state, .veilProbing)
    }

    func testTransportEvent_StreamLabels_AreStable() {
        let fail = TransportEvent.streamFailed(
            method: .quic,
            kind: .midSessionTimeout,
            via: .direct(.h3)
        )
        XCTAssertTrue(fail.shortLabel.contains("stream-fail"))
        XCTAssertTrue(fail.shortLabel.contains("quic"))

        let sup = TransportEvent.streamSuppressed(method: .quic, ttlSeconds: 300)
        XCTAssertTrue(sup.shortLabel.contains("stream-suppress"))
        XCTAssertTrue(sup.shortLabel.contains("300"))
    }

    // `mapStreamFailureKind` is a pure classifier but lives on the @MainActor
    // `MessageStreamManager`, so the test has to be isolated to reach it synchronously.
    @MainActor
    func testMapStreamFailureKind_TimeoutAndWrite() {
        XCTAssertEqual(
            MessageStreamManager.mapStreamFailureKind(
                rpcKind: .streamTimeout,
                error: nil,
                wasConnected: false
            ),
            .openTimeout
        )
        XCTAssertEqual(
            MessageStreamManager.mapStreamFailureKind(
                rpcKind: .streamTimeout,
                error: nil,
                wasConnected: true
            ),
            .midSessionTimeout
        )
        let writeErr = RPCError(code: .unavailable, message: "Write failed.")
        XCTAssertEqual(
            MessageStreamManager.mapStreamFailureKind(
                rpcKind: .transportUnknown,
                error: writeErr,
                wasConnected: true
            ),
            .writeFailed
        )
    }
}

private actor MockProxyEffector: ProxyEffector {
    private var starts = 0
    private var stops = 0
    private let startEvent: TransportEvent

    init(startEvent: TransportEvent = .proxyStartFailed(relay: nil, reason: "unexpected")) {
        self.startEvent = startEvent
    }

    func start() async -> TransportEvent {
        starts += 1
        return startEvent
    }

    func stop() async { stops += 1 }
    func updateRelays(_ relays: [VeilRelay]) async { _ = relays }
    func startCalls() -> Int { starts }
    func stopCalls() -> Int { stops }
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
