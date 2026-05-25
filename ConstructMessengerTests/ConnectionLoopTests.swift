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

// MARK: - Mock Runtime

final class MockIceProxyRuntime: IceProxyRuntime, @unchecked Sendable {
    var startResult: Result<UInt16, IceProxyRuntimeError> = .success(54321)
    var stopCallCount = 0
    private var _alive = false

    func start(_ request: IceTransportRequest) -> Result<UInt16, IceProxyRuntimeError> {
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
}
