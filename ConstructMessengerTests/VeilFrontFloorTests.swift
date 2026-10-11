//
//  VeilFrontFloorTests.swift
//  ConstructMessengerTests
//
//  The pure floor decision behind the ≥2-usable-fronts top-up
//  (decisions/veil-front-topup-keep-two-usable.md). The issuance side rides existing,
//  separately-tested paths (VeilAlternatesCache / verifyAndLearn); what is new and worth
//  pinning is the count: distinct, capped, minus the one we just saw fail.
//

import XCTest
@testable import Construct_Messenger

final class VeilFrontFloorTests: XCTestCase {

    private let a = "a.example:443"
    private let b = "b.example:443"
    private let c = "c.example:443"

    // MARK: - usableCount

    func testCountsOnlyFrontsWithALiveCapability() {
        let live: Set<String> = [a, c]   // b has no live cap
        let n = VeilFrontFloorMaintainer.usableCount(
            candidates: [a, b, c], hasLiveCap: { live.contains($0) }
        )
        XCTAssertEqual(n, 2)
    }

    func testDeduplicatesRepeatedAddresses() {
        let n = VeilFrontFloorMaintainer.usableCount(
            candidates: [a, a, a], hasLiveCap: { _ in true }
        )
        XCTAssertEqual(n, 1)
    }

    func testIgnoresEmptyAddresses() {
        let n = VeilFrontFloorMaintainer.usableCount(
            candidates: ["", a, ""], hasLiveCap: { _ in true }
        )
        XCTAssertEqual(n, 1)
    }

    /// A capped-but-blocked front (the one just reported unavailable) must not count, or it
    /// masks the shortage and the reactive top-up never fires.
    func testExcludedFrontDoesNotCountEvenWithALiveCap() {
        let n = VeilFrontFloorMaintainer.usableCount(
            candidates: [a, b], excluding: [a], hasLiveCap: { _ in true }
        )
        XCTAssertEqual(n, 1, "the just-failed front still has a cached cap but is not usable")
    }

    func testZeroWhenNothingCapped() {
        let n = VeilFrontFloorMaintainer.usableCount(
            candidates: [a, b, c], hasLiveCap: { _ in false }
        )
        XCTAssertEqual(n, 0)
    }

    // MARK: - isBelowFloor

    func testFloorIsTwo() {
        XCTAssertEqual(VeilFrontFloorMaintainer.floor, 2)
    }

    func testBelowFloorBoundary() {
        XCTAssertTrue(VeilFrontFloorMaintainer.isBelowFloor(0))
        XCTAssertTrue(VeilFrontFloorMaintainer.isBelowFloor(1))
        XCTAssertFalse(VeilFrontFloorMaintainer.isBelowFloor(2))
        XCTAssertFalse(VeilFrontFloorMaintainer.isBelowFloor(3))
    }

    /// The scenario the design targets: two saved fronts, one goes down → exactly one usable
    /// remains → below floor → top-up should fire (and one usable remains to carry the RPC).
    func testOneOfTwoDownIsBelowFloorButStillReachable() {
        let n = VeilFrontFloorMaintainer.usableCount(
            candidates: [a, b], excluding: [a], hasLiveCap: { _ in true }
        )
        XCTAssertTrue(VeilFrontFloorMaintainer.isBelowFloor(n))
        XCTAssertGreaterThanOrEqual(n, 1)
    }
}
