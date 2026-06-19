//
//  DeviceIdOrderingTests.swift
//  ConstructMessengerTests
//
//  Phase 0 (characterization) of SESSION_COORDINATOR_REFACTOR_SPEC.
//
//  `DeviceIdOrdering.isNaturalInitiator` is the spine of the session tie-break: it decides,
//  symmetrically across two devices, which side takes the INITIATOR role and which waits as
//  RESPONDER. The upcoming SessionReducer will depend on this predicate, so these tests pin
//  its CURRENT behaviour exactly — they are the regression oracle, not aspirational specs.
//

import XCTest
@testable import Construct_Messenger

final class DeviceIdOrderingTests: XCTestCase {

    // The exact pair from the production logs that motivated the refactor.
    // First UUID byte 0xea > 0x0a, so `ea134859…` is the natural INITIATOR.
    private let idHigh = "ea134859-6460-4a41-9135-39a36da148ac"
    private let idLow  = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

    // MARK: - Antisymmetry: exactly one side initiates

    func testDistinctIds_ExactlyOneIsInitiator() {
        let highWins = DeviceIdOrdering.isNaturalInitiator(myId: idHigh, peerId: idLow)
        let lowWins  = DeviceIdOrdering.isNaturalInitiator(myId: idLow, peerId: idHigh)
        XCTAssertTrue(highWins, "Higher deviceId must be the natural INITIATOR")
        XCTAssertFalse(lowWins, "Lower deviceId must be the natural RESPONDER")
        XCTAssertNotEqual(highWins, lowWins, "Tie-break must elect exactly one INITIATOR")
    }

    func testAntisymmetry_HoldsForManyRandomPairs() {
        for _ in 0..<200 {
            let a = UUID().uuidString
            let b = UUID().uuidString
            let aWins = DeviceIdOrdering.isNaturalInitiator(myId: a, peerId: b)
            let bWins = DeviceIdOrdering.isNaturalInitiator(myId: b, peerId: a)
            // For any two distinct UUIDs, never both initiators and never both responders.
            XCTAssertNotEqual(aWins, bWins, "Both sides agreed on the same role for \(a) / \(b)")
        }
    }

    // MARK: - Equal ids edge (self / duplicate)

    func testEqualIds_NeitherIsInitiator() {
        // compare == .orderedSame → isNaturalInitiator is false for both directions.
        // Pinning this guards the degenerate self-pairing case (e.g. same-device echo).
        XCTAssertFalse(DeviceIdOrdering.isNaturalInitiator(myId: idHigh, peerId: idHigh))
        XCTAssertEqual(DeviceIdOrdering.compare(idHigh, idHigh), .orderedSame)
    }

    // MARK: - Determinism

    func testCompare_IsDeterministic() {
        let first = DeviceIdOrdering.compare(idHigh, idLow)
        for _ in 0..<50 {
            XCTAssertEqual(DeviceIdOrdering.compare(idHigh, idLow), first)
        }
        XCTAssertEqual(first, .orderedDescending)
    }

    // MARK: - UUID byte ordering (not lexicographic string ordering)

    func testUuidOrdering_UsesByteCompareNotStringCompare() {
        // These two UUIDs differ first at byte 0: 0x10 vs 0x09.
        let higher = "10000000-0000-0000-0000-000000000000"
        let lower  = "09ffffff-ffff-ffff-ffff-ffffffffffff"
        XCTAssertEqual(DeviceIdOrdering.compare(higher, lower), .orderedDescending)
        XCTAssertTrue(DeviceIdOrdering.isNaturalInitiator(myId: higher, peerId: lower))
    }

    func testUuidOrdering_DiffersOnlyInLaterByte() {
        let a = "00000000-0000-0000-0000-0000000000ff"
        let b = "00000000-0000-0000-0000-0000000000fe"
        XCTAssertEqual(DeviceIdOrdering.compare(a, b), .orderedDescending)
    }

    // MARK: - Non-UUID literal fallback (cross-format stability)

    func testNonUuidStrings_FallBackToLiteralCompare() {
        XCTAssertEqual(DeviceIdOrdering.compare("device-b", "device-a"), .orderedDescending)
        XCTAssertTrue(DeviceIdOrdering.isNaturalInitiator(myId: "device-b", peerId: "device-a"))
    }

    func testMixedUuidAndNonUuid_StableAndAntisymmetric() {
        // One parses as a UUID, the other does not → literal compare path. Only requirement
        // we pin is stability + antisymmetry, not a particular winner.
        let uuid = idHigh
        let plain = "zzzz"
        let r1 = DeviceIdOrdering.isNaturalInitiator(myId: uuid, peerId: plain)
        let r2 = DeviceIdOrdering.isNaturalInitiator(myId: plain, peerId: uuid)
        XCTAssertNotEqual(r1, r2)
        XCTAssertEqual(DeviceIdOrdering.compare(uuid, plain), DeviceIdOrdering.compare(uuid, plain))
    }
}
