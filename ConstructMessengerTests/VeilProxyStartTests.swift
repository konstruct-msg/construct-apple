//
//  VeilProxyStartTests.swift
//  ConstructMessengerTests
//
//  A start suspends while it dials, and the actor let a second one in: that one passed
//  `stopIfRunning()` with nothing up yet and overwrote the first one's listener without stopping
//  it. The router then stopped "the stray proxy" by stopping whatever was up — the newer one
//  (TODO 164, 2026-10-19; Android's twin is construct-android #150).
//

import Foundation
import XCTest
@testable import Construct_Messenger

final class VeilProxyStartTests: XCTestCase {

    private func relay(_ address: String) -> VeilRelay { VeilRelay(address: address, bridgeCert: "") }

    /// Mutation: start without waiting for the one in flight — B starts with nothing stopped
    /// and A commits over it, which reddens the sequence.
    func testASecondStartStopsTheFirstOnlyOnceItIsUp() async throws {
        let runtime = RecordingRuntime()
        let gate = Gate()
        let proxy = VeilProxy(runtime: runtime, fingerprint: { await gate.pass(); return Data() })

        let a = Task { try await proxy.ensure(relay: self.relay("a:443")) }
        await gate.untilHeld()
        let b = Task { try await proxy.ensure(relay: self.relay("b:443")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()

        _ = try await a.value
        let up = try await b.value

        XCTAssertEqual(runtime.calls, ["start a:443", "stop", "start b:443"])
        let port = await proxy.port
        XCTAssertEqual(port, up.port)
    }

    /// Mutation: drop the stop epoch — the start runs its probe race after the stop and leaves
    /// a proxy up nobody wants.
    func testAStopWhileStartingLeavesNothingUp() async throws {
        let runtime = RecordingRuntime()
        let gate = Gate()
        let proxy = VeilProxy(runtime: runtime, fingerprint: { await gate.pass(); return Data() })

        let a = Task { try await proxy.ensure(relay: self.relay("a:443")) }
        await gate.untilHeld()
        await proxy.stop()
        await gate.release()

        do {
            _ = try await a.value
            XCTFail("a start stopped mid-way must not report a proxy")
        } catch VeilProxyError.stopped {}
        XCTAssertEqual(runtime.calls, [])
        let port = await proxy.port
        XCTAssertNil(port)
    }

    /// Mutation: stop the proxy on a stale `proxyStarted` (the old router) — a second stop reddens.
    func testTheRouterDropsAStaleStartWithoutStoppingWhatIsUp() async throws {
        VeilProxyStore.saveMode(.on)
        let effector = GatedProxyEffector()
        let router = TransportRouter(
            config: .default,
            proxyEffector: effector,
            channelEffector: NoChannelEffector(),
            uiEffector: NoUIEffector()
        )

        await router.bootstrap()
        await router.send(.veilModeChanged(.on, censored: false))
        await effector.untilStarting()
        await router.send(.veilModeChanged(.off, censored: false))
        let stopsAfterOff = await effector.stopCalls()
        XCTAssertGreaterThan(stopsAfterOff, 0)

        await effector.release()
        try await Task.sleep(nanoseconds: 200_000_000)

        let stops = await effector.stopCalls()
        XCTAssertEqual(stops, stopsAfterOff)
        VeilProxyStore.saveMode(.auto)
    }
}

// MARK: - Doubles

private final class RecordingRuntime: VeilProxyRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var nextPort: UInt16 = 40_000

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return log }

    func startUnified(relay: VeilRelay, fingerprint: Data, scoresPath: String?) -> Result<VeilStartOutcome, VeilProxyRuntimeError> {
        lock.lock(); defer { lock.unlock() }
        log.append("start \(relay.address)")
        nextPort += 1
        return .success(VeilStartOutcome(port: nextPort, method: .obfs4, latencyMs: 1))
    }

    func start(_ request: VeilTransportRequest) -> Result<UInt16, VeilProxyRuntimeError> { .success(0) }
    func startSecondary(bridgeLine: String, address: String) -> Result<UInt16, VeilProxyRuntimeError> { .success(0) }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        log.append("stop")
    }
}

/// Holds the first caller of `pass()` until `release()`; later callers go straight through.
private actor Gate {
    private var calls = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func pass() async {
        calls += 1
        guard calls == 1, !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func untilHeld() async {
        while waiter == nil { await Task.yield() }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor GatedProxyEffector: ProxyEffector {
    private var stops = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func start() async -> TransportEvent {
        if !released { await withCheckedContinuation { waiter = $0 } }
        return .proxyStarted(relay: "relay.example:443", port: 49_262, restarted: true)
    }

    func untilStarting() async {
        while waiter == nil { await Task.yield() }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    func listenerIsAlive() async -> Bool { true }
    func stop() async { stops += 1 }
    func demote(relay address: String) async { _ = address }
    func updateRelays(_ relays: [VeilRelay]) async { _ = relays }
    func stopCalls() -> Int { stops }
}

private actor NoChannelEffector: ChannelEffector {
    func invalidateClient() async {}
    func setVeilPort(_ port: UInt16?) async { _ = port }
}

private actor NoUIEffector: UIEffector {
    func publish(state: TransportState, event: TransportEvent, transition: TransitionLogEntry) async {
        _ = (state, event, transition)
    }
}
