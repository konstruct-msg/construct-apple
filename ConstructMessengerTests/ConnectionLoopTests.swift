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

    func testTransportReducer_DirectFailureDoesNotEscalateWhenVEILFallbackDisabled() {
        let config = TransportConfig(
            directFailThreshold: 2,
            allowDirectToVeilEscalation: false,
            veilDegradedFailThreshold: 2,
            maxProbeAttempts: 3,
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
