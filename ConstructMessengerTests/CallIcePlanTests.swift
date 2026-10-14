//
//  CallIcePlanTests.swift
//  ConstructMessengerTests
//
//  With VEIL `on` a call goes through TURN only, over TLS where offered, and never falls back to a
//  direct call (vault security/konstrukt-unobservability-map.md, D8).
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

    func testWithoutVeilNothingChanges() throws {
        let plan = try XCTUnwrap(CallIcePlan.make(turnURLs: turn, username: "u", credential: "c", veilOn: false))
        XCTAssertEqual(plan.policy, .all)
        XCTAssertEqual(plan.servers.flatMap(\.urls), turn)

        let fallback = try XCTUnwrap(CallIcePlan.make(turnURLs: nil, username: "", credential: "", veilOn: false))
        XCTAssertEqual(fallback.servers.flatMap(\.urls), [CallIcePlan.ownStunFallback])
        XCTAssertFalse(fallback.servers.flatMap(\.urls).contains { $0.contains("google") || $0.contains("cloudflare") })
    }
}
