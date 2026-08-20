//
//  MidSessionDeathEscalationTests.swift
//  ConstructMessengerTests
//
//  2026-08-11, a laptop soak on the same Wi-Fi as two test devices, measuring the path directly:
//
//      tcp                 ok    57ms
//      tls_h2              ok    121ms   TLS1.3 ALPN=h2
//      unary_pow           ok    123ms
//      channel_hold_unary  FAIL  n=6 [72, 10005, 10004, 234, 69, 10005] ms
//                                last_error: UNAVAILABLE: recvmsg:Operation timed out
//      h2_hold             ok    held 60s — PINGs sent=12 ACKs≈7
//      message_stream      FAIL  DEADLINE_EXCEEDED, first_frame_ms=null, msgs_recv=0
//
//  pcap of the failing flow: SYN 10:11:51.593, last server packet 10:12:01.990 (~10.4s), then the
//  client pushes seq 1311→2699 against a frozen `ack 4880` and retransmits 20s later. No RST from
//  the network, no ICMP. Establishing works; staying established does not.
//
//  The device never escalated to VEIL on its own, and could not have: every reconnect opened
//  successfully, and `.streamOpened` on direct resets the consecutive-fail counter to 0 — as does
//  `.rpcSucceeded`, which this network also keeps granting (229ms). So a young death scored one
//  tick against a threshold of two and was erased before the second ever arrived.
//
//  Two defects, one symptom:
//    1. `mapStreamFailureKind` consulted `wasConnected` only on the timeout branch, so a 25s-old
//       stream dying with "Stream unexpectedly closed" reached the router as plain `.closed` —
//       indistinguishable from a stream that never opened.
//    2. The reducer discarded the kind entirely (`case .streamFailed(_, _, let via)`).
//

import XCTest
import GRPCCore   // RPCError — the input mapStreamFailureKind classifies
@testable import Construct_Messenger

final class MidSessionDeathEscalationTests: XCTestCase {

    private let config = TransportConfig()
    private let now = Date(timeIntervalSince1970: 1_786_432_743)

    private func reduce(_ state: TransportState, _ event: TransportEvent) -> (state: TransportState, effects: [TransportEffect]) {
        TransportReducer.reduce(state: state, event: event, config: config, now: now)
    }

    // MARK: - The incident

    func testAStreamThatDiedYoungEscalatesWithoutWaitingForASecondFailure() {
        // On this network the second failure never arrives uncontested: the reconnect in between
        // opens fine and zeroes the counter.
        let (state, effects): (TransportState, [TransportEffect]) = reduce(
            .direct(consecutiveFails: 0),
            .streamFailed(method: .h2, kind: .midSessionClosed, via: .direct(.h2))
        )
        XCTAssertEqual(state, .veilProbing, "a path that establishes and then breaks must escalate")
        XCTAssertTrue(effects.contains(.requestProxyStart))
    }

    func testEveryMidSessionKindCarriesTheSameWeight() {
        for kind in [StreamFailureKind.midSessionTimeout, .midSessionClosed, .midSessionUnknown, .writeFailed] {
            let (state, _): (TransportState, [TransportEffect]) = reduce(
                .direct(consecutiveFails: 0),
                .streamFailed(method: .h2, kind: kind, via: .direct(.h2))
            )
            XCTAssertEqual(state, .veilProbing, "\(kind) is a death after establishment")
        }
    }

    func testWasConnectedSurvivesTheCloseAndUnknownBranches() {
        // The classifier fed the reducer a fact it had already computed and thrown away.
        XCTAssertEqual(
            MainActor.assumeIsolated { MessageStreamManager.mapStreamFailureKind(
                rpcKind: .transportUnknown,
                error: RPCError(code: .unavailable, message: "Stream unexpectedly closed."),
                wasConnected: true
            ) },
            .midSessionClosed
        )
        XCTAssertEqual(
            MainActor.assumeIsolated { MessageStreamManager.mapStreamFailureKind(
                rpcKind: .transportUnknown,
                error: RPCError(code: .unavailable, message: "Stream unexpectedly closed."),
                wasConnected: false
            ) },
            .closed,
            "a stream that never opened must not read as a mid-session death"
        )
    }

    // MARK: - What must NOT happen

    func testAnOpenFailureStillTakesTwo() {
        // Unchanged behaviour, and deliberately so: an open failure IS refuted by the next
        // successful open, so one is not evidence about the path.
        let (afterFirst, effects): (TransportState, [TransportEffect]) = reduce(
            .direct(consecutiveFails: 0),
            .streamFailed(method: .quic, kind: .openTimeout, via: .direct(.h3))
        )
        XCTAssertEqual(afterFirst, .direct(consecutiveFails: 1))
        XCTAssertTrue(effects.isEmpty)

        let (afterSecond, _): (TransportState, [TransportEffect]) = reduce(afterFirst, .streamFailed(method: .h2, kind: .openTimeout, via: .direct(.h2)))
        XCTAssertEqual(afterSecond, .veilProbing)
    }

    func testAMidSessionDeathOnVEILDoesNotEscalate() {
        // We are already on VEIL; counting it against the direct path would be nonsense, and
        // escalating out of VEIL into VEIL is a loop.
        let (state, effects): (TransportState, [TransportEffect]) = reduce(
            .direct(consecutiveFails: 0),
            .streamFailed(method: .veil, kind: .midSessionClosed, via: .veil(port: 1234, relay: "relay"))
        )
        XCTAssertEqual(state, .direct(consecutiveFails: 0))
        XCTAssertTrue(effects.isEmpty)
    }

    func testEscalationStillObeysTheUserTurningVEILOff() {
        // A manual `.off` disables escalation entirely. A mid-session death must not smuggle VEIL
        // back on — that was a real device bug on the proxyStarted path once already.
        var offConfig = TransportConfig()
        offConfig.allowDirectToVeilEscalation = false
        let (state, effects): (TransportState, [TransportEffect]) = TransportReducer.reduce(
            state: .direct(consecutiveFails: 0),
            event: .streamFailed(method: .h2, kind: .midSessionClosed, via: .direct(.h2)),
            config: offConfig,
            now: now
        )
        XCTAssertEqual(state, .direct(consecutiveFails: 2), "counted, but not acted on")
        XCTAssertTrue(effects.isEmpty)
    }

    func testASuccessfulOpenStillClearsAnOpenFailureStreak() {
        // The reset this fix works around must stay: on a healthy network a stumble followed by a
        // good open is not a reason to drift toward VEIL.
        let (state, _): (TransportState, [TransportEffect]) = reduce(.direct(consecutiveFails: 1), .streamOpened(method: .h2, via: .direct(.h2)))
        XCTAssertEqual(state, .direct(consecutiveFails: 0))
    }
}
