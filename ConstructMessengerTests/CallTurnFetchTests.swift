//
//  CallTurnFetchTests.swift
//  ConstructMessengerTests
//
//  A callee woken by its VoIP push with VEIL `on` asks for TURN before the tunnel is up. On
//  2026-11-16 (build 779) all three tries were spent in two seconds:
//
//      13:41:55  Incoming VoIP push — CallKit notified
//      13:41:58  CallKit answer
//      13:41:58  TURN fetch 1/3 failed: VeilTunnelNotUp()
//      13:42:00  TURN fetch 3/3 failed: VeilTunnelNotUp()
//      13:42:00  Failed to accept call: noRelay
//      13:42:04  offer through the tunnel — for a call already over
//
//  `fetchTurnWithRetry` now waits for the route once, and the wait is not an attempt.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class CallTurnFetchTests: XCTestCase {

    private struct Transient: Error {}

    private func credentials() -> Shared_Proto_Signaling_V1_TurnCredentials {
        var turn = Shared_Proto_Signaling_V1_TurnCredentials()
        turn.urls = ["turn:t.example:3478?transport=udp"]
        turn.username = "u"
        turn.credential = "c"
        return turn
    }

    /// Mutation: drop the `VeilTunnelNotUp` clause — the three tries go to a tunnel still down.
    func testATunnelStillComingUpIsWaitedForAndThenAsked() async {
        var routed = false
        var waits = 0
        let turn = await CallManager.shared.fetchTurnWithRetry(
            callId: "c1",
            fetch: { _ in
                guard routed else { throw VeilTunnelNotUp() }
                return self.credentials()
            },
            waitForRoute: {
                waits += 1
                routed = true
                return true
            }
        )
        XCTAssertEqual(turn?.urls, ["turn:t.example:3478?transport=udp"],
                       "the callee answers once the tunnel is up, instead of failing with no relay")
        XCTAssertEqual(waits, 1)
    }

    /// Mutation: count the wait as an attempt — one try fewer once the route is there.
    func testTheWaitIsNotAnAttempt() async {
        var calls = 0
        let turn = await CallManager.shared.fetchTurnWithRetry(
            callId: "c1",
            attempts: 2,
            fetch: { _ in
                calls += 1
                if calls == 1 { throw VeilTunnelNotUp() }
                if calls == 2 { throw Transient() }
                return self.credentials()
            },
            waitForRoute: { true }
        )
        XCTAssertNotNil(turn, "two attempts after the wait: the transient failure, then the credentials")
        XCTAssertEqual(calls, 3)
    }

    /// The wait happens once: a tunnel that drops again is an ordinary failed attempt, so a call
    /// cannot wait twice the bound. Mutation: drop `!waitedForRoute`.
    func testTheRouteIsWaitedForOnce() async {
        var waits = 0
        var calls = 0
        let turn = await CallManager.shared.fetchTurnWithRetry(
            callId: "c1",
            attempts: 1,
            fetch: { _ in
                calls += 1
                throw VeilTunnelNotUp()
            },
            // A second wait would be told "no route", so waiting each time ends the fetch rather
            // than spinning.
            waitForRoute: {
                waits += 1
                return waits == 1
            }
        )
        XCTAssertNil(turn)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(calls, 2, "the try before the wait and the one attempt after it")
    }

    /// The tunnel never came: no relay, and no tries spent on a route that is not there.
    /// Mutation: `continue` after a failed wait.
    func testATunnelThatNeverComesEndsTheFetch() async {
        var calls = 0
        let turn = await CallManager.shared.fetchTurnWithRetry(
            callId: "c1",
            fetch: { _ in
                calls += 1
                throw VeilTunnelNotUp()
            },
            waitForRoute: { false }
        )
        XCTAssertNil(turn)
        XCTAssertEqual(calls, 1)
    }
}
