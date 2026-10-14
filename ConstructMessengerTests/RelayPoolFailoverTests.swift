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
}
