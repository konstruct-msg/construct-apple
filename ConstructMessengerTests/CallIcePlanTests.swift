//
//  CallIcePlanTests.swift
//  ConstructMessengerTests
//
//  Every call goes through TURN only and never falls back to a direct call (owner, 2026-10-16);
//  with VEIL `on`, over TLS where offered (vault security/konstrukt-unobservability-map.md, D8).
//

import XCTest
@testable import Construct_Messenger

final class CallIcePlanTests: XCTestCase {

    private let turn = ["turn:t.example:3478?transport=udp", "turn:t.example:3478?transport=tcp",
                        "turns:t.example:5349?transport=tcp"]

    func testWithVeilOnTheCallIsRelayedOverTLS() throws {
        let plan = try XCTUnwrap(CallIcePlan.make(turnURLs: turn, username: "u", credential: "c", veilOn: true))
        XCTAssertEqual(plan.policy, .relay, "no direct candidates, no peer address")
        XCTAssertEqual(plan.servers.flatMap(\.urls), ["turns:t.example:5349?transport=tcp"])
        XCTAssertEqual(plan.servers.first?.username, "u")
    }

    func testWithVeilOnAndNoTLSOfferedItIsStillRelayOnly() throws {
        let plain = Array(turn.prefix(2))
        let plan = try XCTUnwrap(CallIcePlan.make(turnURLs: plain, username: "u", credential: "c", veilOn: true))
        XCTAssertEqual(plan.policy, .relay)
        XCTAssertEqual(plan.servers.flatMap(\.urls), plain)
    }

    /// A STUN fallback is a direct call; with VEIL `on` no call is better than that one.
    func testWithVeilOnAndNoTurnThereIsNoCall() {
        XCTAssertNil(CallIcePlan.make(turnURLs: nil, username: "", credential: "", veilOn: true))
        XCTAssertNil(CallIcePlan.make(turnURLs: [], username: "", credential: "", veilOn: true))
    }

    /// The rule before 2026-10-16 was "relay only with VEIL on"; a direct policy for VEIL off reddens this.
    func testWithoutVeilTheCallIsStillRelayOnlyOverEveryTurnURL() throws {
        let plan = try XCTUnwrap(CallIcePlan.make(turnURLs: turn, username: "u", credential: "c", veilOn: false))
        XCTAssertEqual(plan.policy, .relay, "a direct call hands the peer our address")
        XCTAssertEqual(plan.servers.flatMap(\.urls), turn, "plain TURN kept for latency without VEIL")
    }

    /// Mutation: bring back the STUN fallback for VEIL off — this reddens.
    func testWithoutVeilAndNoTurnThereIsNoCall() {
        XCTAssertNil(CallIcePlan.make(turnURLs: nil, username: "", credential: "", veilOn: false))
        XCTAssertNil(CallIcePlan.make(turnURLs: [], username: "", credential: "", veilOn: false))
    }
}
