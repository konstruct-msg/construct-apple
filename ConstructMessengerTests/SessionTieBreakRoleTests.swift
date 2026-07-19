//
//  SessionTieBreakRoleTests.swift
//  ConstructMessengerTests
//
//  The single tie-break authority: `SessionReducer.tieBreakRole` decides, symmetrically across
//  two devices, which side is INITIATOR and which waits as RESPONDER. It replaces the old
//  `DeviceIdOrdering` (UUID-byte compare) — which diverged from the Rust core (`message_router.rs
//  ::tie_break_role`, plain string compare, higher userId = INITIATOR) on non-canonical / mixed-
//  case ids. These tests pin the unified rule AND its parity with Rust; a disagreement between the
//  two implementations means both-initiator / both-responder → permanent deadlock.
//

import XCTest
@testable import Construct_Messenger

final class SessionTieBreakRoleTests: XCTestCase {

    // The exact pair from the production desync logs (ServerUserIds, 36-char UUIDs — NOT deviceIds).
    private let idHigh = "ea134859-6460-4a41-9135-39a36da148ac"
    private let idLow  = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

    // MARK: - Antisymmetry: exactly one side initiates

    func testDistinctIds_ExactlyOneIsInitiator() {
        XCTAssertEqual(SessionReducer.tieBreakRole(myId: idHigh, peerId: idLow), .initiator)
        XCTAssertEqual(SessionReducer.tieBreakRole(myId: idLow, peerId: idHigh), .responder)
        XCTAssertTrue(SessionReducer.isNaturalInitiator(myId: idHigh, peerId: idLow))
        XCTAssertFalse(SessionReducer.isNaturalInitiator(myId: idLow, peerId: idHigh))
    }

    func testAntisymmetry_HoldsForManyRandomPairs() {
        for _ in 0..<200 {
            let a = UUID().uuidString.lowercased()
            let b = UUID().uuidString.lowercased()
            guard a != b else { continue }
            let aInit = SessionReducer.tieBreakRole(myId: a, peerId: b) == .initiator
            let bInit = SessionReducer.tieBreakRole(myId: b, peerId: a) == .initiator
            XCTAssertNotEqual(aInit, bInit, "Both sides agreed on the same role for \(a) / \(b)")
        }
    }

    // MARK: - Equal ids edge (self / duplicate)

    func testEqualIds_NeitherIsInitiator() {
        XCTAssertFalse(SessionReducer.isNaturalInitiator(myId: idHigh, peerId: idHigh))
        XCTAssertFalse(SessionReducer.isNaturalInitiator(myId: idLow, peerId: idLow))
    }

    // MARK: - Determinism

    func testRole_IsDeterministic() {
        let first = SessionReducer.tieBreakRole(myId: idHigh, peerId: idLow)
        for _ in 0..<50 {
            XCTAssertEqual(SessionReducer.tieBreakRole(myId: idHigh, peerId: idLow), first)
        }
        XCTAssertEqual(first, .initiator)
    }

    // MARK: - Rust parity (construct-core message_router.rs::tie_break_role)

    /// Rust: `if my_user_id > contact_id { Initiator } else { Responder }` — plain string compare.
    /// These are the exact cases pinned in the Rust unit test (`tie_break_role("bob","alice") ==
    /// Initiator`), reproduced Swift-side so the two stay in lockstep.
    func testRustParity_StringCompare_HigherWins() {
        XCTAssertEqual(SessionReducer.tieBreakRole(myId: "bob", peerId: "alice"), .initiator)
        XCTAssertEqual(SessionReducer.tieBreakRole(myId: "alice", peerId: "bob"), .responder)
        // Canonical lowercase UUIDs: string order == UUID-byte order, so the old byte-compare
        // pair still resolves the same way under the unified string rule.
        XCTAssertEqual(SessionReducer.tieBreakRole(
            myId: "10000000-0000-0000-0000-000000000000",
            peerId: "09ffffff-ffff-ffff-ffff-ffffffffffff"), .initiator)
    }

    // MARK: - Non-UUID ids (cross-format stability — matches Rust literal compare)

    func testNonUuidStrings_StringCompare() {
        XCTAssertEqual(SessionReducer.tieBreakRole(myId: "device-b", peerId: "device-a"), .initiator)
        XCTAssertEqual(SessionReducer.tieBreakRole(myId: "device-a", peerId: "device-b"), .responder)
    }
}
