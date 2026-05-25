//
//  ConnectionLoopTests.swift
//  ConstructMessengerTests
//
//  Integration tests for ConnectionLoop: directFails counting, ICE activation,
//  relay failure tracking, network-aware penalisation, and MCC pre-activation.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

// MARK: - Test helpers

private extension IceTransportRequest {
    var address: String {
        switch self {
        case .webTunnel(let address, _, _, _, _, _): return address
        case .tlsPinned(_, let address, _, _, _):    return address
        case .tlsUnpinned(_, let address, _):        return address
        case .plainObfs4(_, let address):            return address
        }
    }
}

// MARK: - Mock Runtime

final class MockIceProxyRuntime: IceProxyRuntime, @unchecked Sendable {
    var startResult: Result<UInt16, IceProxyRuntimeError> = .success(54321)
    var stopCallCount = 0
    var startedAddresses: [String] = []
    private var _alive = false

    func start(_ request: IceTransportRequest) -> Result<UInt16, IceProxyRuntimeError> {
        startedAddresses.append(request.address)
        if case .success = startResult { _alive = true }
        return startResult
    }

    func startSecondary(bridgeLine: String, address: String) -> Result<UInt16, IceProxyRuntimeError> {
        .failure(.startFailed(code: -1))
    }

    func stop() { stopCallCount += 1; _alive = false }
    func isAlive() -> Bool { _alive }
}

// MARK: - Tests

final class ConnectionLoopTests: XCTestCase {

    // MARK: - Setup

    override func setUp() async throws {
        // Isolate tests from simulator UserDefaults state:
        // IceMode=.on (set by the app) causes ConnectionLoop.init to pre-activate ICE
        // via the P2 mode=.on check, breaking tests that expect directFails=0 initially.
        IceProxyStore.saveMode(.auto)
        CensoredNetworkDetector._testOverride = false
    }

    override func tearDown() async throws {
        IceProxyStore.saveMode(.auto)
        CensoredNetworkDetector._testOverride = nil
        await ConnectionLoop.shared.reset()
    }

    // MARK: - Helpers

    private func makeLoop(
        relays: [IceRelay] = [],
        runtime: MockIceProxyRuntime = MockIceProxyRuntime()
    ) -> ConnectionLoop {
        let proxy = IceProxy(runtime: runtime)
        return ConnectionLoop(relays: relays, proxy: proxy)
    }

    private func relay(address: String = "relay.test:443") -> IceRelay {
        IceRelay(address: address, bridgeCert: "test-cert=abc123")
    }

    private var transportError: Error {
        RPCError(code: .unavailable, message: "connection lost")
    }

    private var webTunnelBlockedError: Error {
        RPCError(code: .unimplemented, message: "Unexpected non-200 HTTP Status Code (404 Not Found).")
    }

    private var authError: Error {
        RPCError(code: .unauthenticated, message: "token expired")
    }

    // MARK: - directFails counting

    func test_directPath_transportError_incrementsDirectFails() async {
        let loop = makeLoop(relays: [relay()])
        await loop.recordFailure(transportError)
        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive, "One failure is below threshold of 2")
    }

    func test_directPath_appLayerError_doesNotIncrementDirectFails() async {
        let loop = makeLoop(relays: [relay()])
        await loop.recordFailure(authError)
        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive, "Auth errors must not count toward directFails")
    }

    func test_directPath_cancelledError_doesNotIncrementDirectFails() async {
        let loop = makeLoop(relays: [relay()])
        await loop.recordFailure(RPCError(code: .cancelled, message: "cancelled"))
        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive, "Cancelled must not count toward directFails")
    }

    // MARK: - ICE threshold

    func test_iceNotActive_initially() async {
        let loop = makeLoop()
        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive)
    }

    func test_iceNotActive_belowThreshold() async {
        let loop = makeLoop(relays: [relay()])
        await loop.recordFailure(transportError)
        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive)
    }

    func test_iceActivates_atThreshold() async {
        let loop = makeLoop(relays: [relay()])
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        let iceActive = await loop.shouldUseICE
        XCTAssertTrue(iceActive, "Two consecutive transport failures must activate ICE")
    }

    // MARK: - recordSuccess

    func test_recordSuccess_clearsDirectFails() async {
        let loop = makeLoop(relays: [relay()])
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        await loop.recordSuccess()
        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive, "recordSuccess must reset directFails to 0")
    }

    // MARK: - reset

    func test_reset_clearsDirectFails() async {
        let loop = makeLoop(relays: [relay()])
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        await loop.reset()
        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive, "reset() must clear directFails")
    }

    func test_reset_stopsProxy() async throws {
        let runtime = MockIceProxyRuntime()
        let loop = makeLoop(relays: [relay()], runtime: runtime)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()
        await loop.reset()
        XCTAssertEqual(runtime.stopCallCount, 1, "reset() must stop the running proxy")
    }

    // MARK: - prepare()

    func test_prepare_returnsNil_onDirectPath() async throws {
        let loop = makeLoop(relays: [relay()])
        let port = try await loop.prepare()
        XCTAssertNil(port, "Direct path must return nil")
    }

    func test_prepare_returnsNil_whenPoolEmpty() async throws {
        let loop = makeLoop(relays: [])
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        let port = try await loop.prepare()
        XCTAssertNil(port, "Empty relay pool must fall back to direct")
    }

    func test_prepare_returnsPort_onIcePath() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let loop = makeLoop(relays: [relay()], runtime: runtime)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        let port = try await loop.prepare()
        XCTAssertEqual(port, 54321)
    }

    func test_prepare_idempotent_sameRelay() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let loop = makeLoop(relays: [relay()], runtime: runtime)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()
        _ = try await loop.prepare()
        XCTAssertEqual(runtime.stopCallCount, 0, "Same relay: proxy must not restart between prepares")
    }

    // MARK: - proxy start failure

    func test_prepare_proxyStartFailed_throws() async {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .failure(.startFailed(code: 1))
        let loop = makeLoop(relays: [relay()], runtime: runtime)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        do {
            _ = try await loop.prepare()
            XCTFail("Expected prepare() to throw on proxy start failure")
        } catch {
            // expected
        }
    }

    func test_prepare_proxyStartFailed_maintainsICEState() async {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .failure(.startFailed(code: 1))
        let loop = makeLoop(relays: [relay()], runtime: runtime)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try? await loop.prepare()
        let iceActive = await loop.shouldUseICE
        XCTAssertTrue(iceActive, "Proxy start failure must not clear ICE activation — retry on next prepare()")
    }

    // MARK: - ICE path failures

    func test_icePathFailure_doesNotChangeDirectFails() async throws {
        let runtime = MockIceProxyRuntime()
        let loop = makeLoop(relays: [relay()], runtime: runtime)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()
        await loop.recordFailure(transportError)
        let iceActive = await loop.shouldUseICE
        XCTAssertTrue(iceActive, "ICE path failure must not change directFails — ICE must remain active")
    }

    func test_staleLocalProxy_stopsProxy() async throws {
        let runtime = MockIceProxyRuntime()
        let loop = makeLoop(relays: [relay()], runtime: runtime)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()
        let staleError = RPCError(code: .unavailable, message: "Connection refused (127.0.0.1:54952)")
        await loop.recordFailure(staleError)
        XCTAssertEqual(runtime.stopCallCount, 1, "staleLocalProxy error must stop the proxy")
    }

    // MARK: - Multiple relays

    func test_onlinePenalisation_switchesRelay() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let relayA = relay(address: "a.test:443")
        let relayB = relay(address: "b.test:443")
        let loop = makeLoop(relays: [relayA, relayB], runtime: runtime)

        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()  // starts on relayA (both at 0, A is first in array)

        await loop.recordFailure(transportError)  // online: penalises relayA

        // relayB now has fewer failures → proxy switches
        _ = try await loop.prepare()
        XCTAssertEqual(runtime.stopCallCount, 1, "Penalised relayA must cause switch to relayB on next prepare()")
    }

    func test_updateRelays_replacesPool() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let loop = makeLoop(relays: [relay(address: "old.test:443")], runtime: runtime)
        await loop.updateRelays([relay(address: "new.test:443")])
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        let port = try await loop.prepare()
        XCTAssertNotNil(port, "prepare() must succeed after updateRelays()")
    }

    // MARK: - Background RPC non-penalisation (P4)

    func test_backgroundRPCFailure_doesNotPenaliseRelay() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let relayA = relay(address: "a.test:443")
        let relayB = relay(address: "b.test:443")
        let loop = makeLoop(relays: [relayA, relayB], runtime: runtime)

        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()  // starts on relayA

        // Background RPC failure (OTPK, bundle fetch) — must NOT penalise relayA
        await loop.recordFailure(transportError, invalidatesConnection: false)
        await loop.recordFailure(transportError, invalidatesConnection: false)

        // relayA still at 0 failures → pool.best() returns relayA → no restart
        _ = try await loop.prepare()
        XCTAssertEqual(runtime.stopCallCount, 0, "Background RPC failure must not penalise relay — proxy must not switch")
    }

    func test_connectionInvalidatingFailure_penalisesRelay() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let relayA = relay(address: "a.test:443")
        let relayB = relay(address: "b.test:443")
        let loop = makeLoop(relays: [relayA, relayB], runtime: runtime)

        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()  // starts on relayA

        // Stream-level failure (invalidatesConnection=true) — must penalise relayA
        await loop.recordFailure(transportError, invalidatesConnection: true)

        // relayB now preferred → proxy switches
        _ = try await loop.prepare()
        XCTAssertEqual(runtime.stopCallCount, 1, "Connection-invalidating failure must penalise relay — proxy must switch to relayB")
    }

    // MARK: - WebTunnel-blocked persistence (P6)

    func test_webTunnelBlocked_persistsAcrossReset() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let relayA = relay(address: "a.test:443")
        let relayB = relay(address: "b.test:443")
        // relayA is first in array — would be chosen on tie
        let loop = makeLoop(relays: [relayA, relayB], runtime: runtime)

        // Activate ICE
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()  // starts on relayA (tie → first in array)

        // relayA gets a WebTunnel-blocked failure — persistent penalty
        await loop.recordFailure(webTunnelBlockedError)

        // Reset simulates a network path change (clears transient failures, stops proxy)
        await loop.reset()
        // stopCallCount = 1 from reset()'s proxy.stop()

        // Re-activate ICE (simulates reconnect attempt after network change)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)

        // Pool failures cleared, but WebTunnel penalty on relayA survived the reset.
        // relayA has effective score = 5 (penalty), relayB has 0 → relayB should be chosen.
        _ = try await loop.prepare()
        XCTAssertEqual(runtime.startedAddresses.last, "b.test:443",
            "WebTunnel-blocked penalty must survive reset — pool must prefer relayB after network change")
    }

    func test_webTunnelBlocked_clearedBySuccess() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let relayA = relay(address: "a.test:443")
        let relayB = relay(address: "b.test:443")
        let loop = makeLoop(relays: [relayA, relayB], runtime: runtime)

        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()  // starts on relayA

        // relayA gets WebTunnel-blocked
        await loop.recordFailure(webTunnelBlockedError)

        // Next prepare() picks relayB
        _ = try await loop.prepare()

        // relayB succeeds — clears its own penalty (none) + resets directFails
        await loop.recordSuccess()

        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive, "recordSuccess must clear directFails")
    }

    // MARK: - Feature 1: Network-aware relay penalisation

    func test_offlineNetwork_doesNotPenaliseRelay() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let relayA = relay(address: "a.test:443")
        let relayB = relay(address: "b.test:443")
        let loop = makeLoop(relays: [relayA, relayB], runtime: runtime)

        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()  // starts on relayA

        // Offline failure — must NOT penalise relayA
        NetworkReachabilityManager.shared.isReachable = false
        await loop.recordFailure(transportError)
        NetworkReachabilityManager.shared.isReachable = true

        // relayA still has 0 failures → pool.best() still returns relayA → no restart
        _ = try await loop.prepare()
        XCTAssertEqual(runtime.stopCallCount, 0, "Offline failure must not penalise relay — proxy must not switch")
    }

    func test_onlineNetwork_penalisesRelay() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let relayA = relay(address: "a.test:443")
        let relayB = relay(address: "b.test:443")
        let loop = makeLoop(relays: [relayA, relayB], runtime: runtime)

        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()  // starts on relayA

        // Online failure — must penalise relayA
        await loop.recordFailure(transportError)

        // relayB now preferred (0 failures vs relayA's 1) → proxy switches
        _ = try await loop.prepare()
        XCTAssertEqual(runtime.stopCallCount, 1, "Online failure must penalise relay — proxy must switch to relayB")
    }

    // MARK: - Feature 2: MCC pre-activation

    func test_censoredCarrier_preActivatesICE() async {
        CensoredNetworkDetector._testOverride = true
        defer { CensoredNetworkDetector._testOverride = nil }

        let loop = makeLoop(relays: [relay()])
        let iceActive = await loop.shouldUseICE
        XCTAssertTrue(iceActive, "Censored carrier must pre-activate ICE without any failures")
    }

    func test_uncensoredCarrier_doesNotPreActivateICE() async {
        CensoredNetworkDetector._testOverride = false
        defer { CensoredNetworkDetector._testOverride = nil }

        let loop = makeLoop(relays: [relay()])
        let iceActive = await loop.shouldUseICE
        XCTAssertFalse(iceActive, "Uncensored carrier must start on the direct path")
    }

    func test_reset_reEvaluatesCensoredStatus() async {
        CensoredNetworkDetector._testOverride = true
        defer { CensoredNetworkDetector._testOverride = nil }

        let loop = makeLoop(relays: [relay()])
        let initialIceActive = await loop.shouldUseICE
        XCTAssertTrue(initialIceActive, "Censored carrier must pre-activate ICE")

        // Simulate moving to an uncensored network (e.g. VPN)
        CensoredNetworkDetector._testOverride = false
        await loop.reset()

        let afterResetIceActive = await loop.shouldUseICE
        XCTAssertFalse(afterResetIceActive, "reset() must re-evaluate censored status — ICE off on uncensored network")
    }

    // MARK: - P7: Stale-proxy force restart

    func test_consecutiveIceFails_forceRestartsProxy() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let loop = makeLoop(relays: [relay()], runtime: runtime)

        // Activate ICE
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()  // start proxy — startCallCount=1

        // 3 consecutive stream failures on the ICE path (proxyRestartThreshold)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)

        // Proxy must have been force-stopped at threshold
        XCTAssertGreaterThanOrEqual(runtime.stopCallCount, 1,
            "3 consecutive ICE stream failures must force-stop the stale proxy")
    }

    func test_consecutiveIceFails_resetOnSuccess() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let loop = makeLoop(relays: [relay()], runtime: runtime)

        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()

        // 2 failures — below threshold, no restart yet
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        let stopCountBefore = runtime.stopCallCount

        // Stream succeeds — counter must reset
        await loop.recordSuccess()

        // 2 more failures — should not trigger restart (counter reset to 0 by success)
        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)

        XCTAssertEqual(runtime.stopCallCount, stopCountBefore,
            "recordSuccess() must reset consecutive fail counter — 2 failures after success must not restart proxy")
    }

    func test_backgroundRPCFailure_doesNotCountTowardProxyRestart() async throws {
        let runtime = MockIceProxyRuntime()
        runtime.startResult = .success(54321)
        let loop = makeLoop(relays: [relay()], runtime: runtime)

        await loop.recordFailure(transportError)
        await loop.recordFailure(transportError)
        _ = try await loop.prepare()

        // 10 background-RPC failures — should not accumulate toward restart threshold
        for _ in 0..<10 {
            await loop.recordFailure(transportError, invalidatesConnection: false)
        }

        XCTAssertEqual(runtime.stopCallCount, 0,
            "Background RPC failures must not count toward stale-proxy restart threshold")
    }
}
