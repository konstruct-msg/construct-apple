//
//  RelayPoolFailoverTests.swift
//  ConstructMessengerTests
//
//  A front this network cannot reach must not come back to the head of the pool each time the
//  pool is rebuilt (2026-10-14: one phone retried it for 16 minutes beside three working fronts).
//

import XCTest
@testable import Construct_Messenger

final class RelayPoolFailoverTests: XCTestCase {

    private func relay(_ address: String) -> VeilRelay {
        VeilRelay(address: address, bridgeCert: "")
    }

    func testOneFailureMovesSelectionToTheNextFront() {
        var pool = RelayPool(relays: [relay("a.example:443"), relay("b.example:443")])
        XCTAssertEqual(pool.best()?.address, "a.example:443")
        pool.recordFailure(address: "a.example:443")
        XCTAssertEqual(pool.best()?.address, "b.example:443")
    }

    /// The rebuild an enable, a discovery change or a voucher makes keeps what failed.
    func testARebuiltPoolKeepsTheFailuresOfFrontsStillListed() async {
        let effector = NativeProxyEffector(initialRelays: [relay("a.example:443"), relay("b.example:443")], blockedPenalty: [:])
        await effector.recordFailureForTesting(address: "a.example:443")
        await effector.updateRelays([relay("a.example:443"), relay("b.example:443"), relay("c.example:443")])
        let chosen = await effector.bestForTesting()
        XCTAssertNotEqual(chosen, "a.example:443", "the failed front stays behind the others")
    }

    func testFailuresOfFrontsNoLongerListedAreDropped() {
        let pool = RelayPool(relays: [relay("b.example:443")], failures: ["a.example:443": 3, "b.example:443": 1])
        XCTAssertEqual(pool.failureCounts, ["b.example:443": 1])
    }

    // MARK: - One start tries every front once

    private struct Down: Error {}

    private func ok(_ port: UInt16) -> VeilProxyEnsureResult {
        VeilProxyEnsureResult(port: port, restarted: true, method: nil, latencyMs: nil)
    }

    /// A front that fails is followed by the next in the same start — no cooldown between them
    /// (2026-10-14: 29 s lost with three working fronts beside the dead one).
    func testAFailedFrontIsFollowedByTheNextInTheSameStart() async {
        let effector = NativeProxyEffector(initialRelays: [relay("dead.example:443"), relay("live.example:443")]) { relay in
            if relay.address == "dead.example:443" { throw Down() }
            return VeilProxyEnsureResult(port: 4242, restarted: true, method: nil, latencyMs: nil)
        }
        let event = await effector.start()
        XCTAssertEqual(event, .proxyStarted(relay: "live.example:443", port: 4242, restarted: true))
    }

    /// Only when every front failed does the router hear a failure — and each was tried once.
    func testEveryFrontFailingIsOneFailureAfterOneTryEach() async {
        let tries = TryCounter()
        let effector = NativeProxyEffector(initialRelays: [relay("a.example:443"), relay("b.example:443"), relay("c.example:443")]) { relay in
            await tries.add(relay.address)
            throw Down()
        }
        let event = await effector.start()
        guard case .proxyStartFailed = event else { return XCTFail("\(event)") }
        let seen = await tries.all
        XCTAssertEqual(seen.sorted(), ["a.example:443", "b.example:443", "c.example:443"])
    }
}

private actor TryCounter {
    private(set) var all: [String] = []
    func add(_ address: String) { all.append(address) }
}

// MARK: - An upload waits for the tunnel

/// VEIL `on` with the tunnel still coming up: an upload waits for it rather than failing
/// (2026-10-14: a file dropped into a chat in those seconds turned red at once).
final class UploadWaitsForTunnelTests: XCTestCase {

    private final class Attempts: @unchecked Sendable {
        var count = 0
    }

    func testAnUploadRefusedForNoTunnelRunsOnceTheTunnelIsUp() async throws {
        let attempts = Attempts()
        let result = try await MediaManager.retryingUpload(delays: [], waitForTunnel: { true }) { () -> Int in
            attempts.count += 1
            if attempts.count == 1 { throw VeilTunnelNotUp() }
            return 7
        }
        XCTAssertEqual(result, 7)
        XCTAssertEqual(attempts.count, 2)
    }

    func testATunnelThatNeverComesFailsTheUpload() async {
        do {
            _ = try await MediaManager.retryingUpload(delays: [], waitForTunnel: { false }) { () -> Int in
                throw VeilTunnelNotUp()
            }
            XCTFail("expected VeilTunnelNotUp")
        } catch {
            XCTAssertTrue(error is VeilTunnelNotUp, "\(error)")
        }
    }

    func testTheWaitEndsWhenTheRouteOpens() async {
        let checks = Attempts()
        let routed = await VeilTunnelWait.untilRouted(limit: 5) {
            checks.count += 1
            return checks.count >= 3
        }
        XCTAssertTrue(routed)
        let never = await VeilTunnelWait.untilRouted(limit: 0) { false }
        XCTAssertFalse(never)
    }
}
