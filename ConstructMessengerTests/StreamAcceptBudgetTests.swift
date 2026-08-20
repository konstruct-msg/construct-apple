//
//  StreamAcceptBudgetTests.swift
//  ConstructMessengerTests
//
//  Stage 2 of decisions/no-client-side-network-learning, in the shape the measurement dictated
//  rather than the one the note guessed.
//
//  The note proposed pre-warming a VEIL standby so promotion would be cheap. On device 2026-08-11
//  promotion already costs 173–468 ms, inside the same second:
//
//      10:43:07  Transport: proxy start gen=1 (async)
//      10:43:07  VEIL: relay=api.divany-kresla.uk:443 method=veil-front port=49549 latency=468ms
//      10:43:51  VEIL: … latency=173ms
//
//  The time goes on the decision instead: every direct attempt burns its full 2.0s accept budget
//  re-confirming what this session already established. So the leash shortens once direct has
//  failed here — to `streamOpenAcceptTimeoutStandby`, a constant that has existed since 2026-05
//  for exactly this and has never had a reader.
//

import XCTest
@testable import Construct_Messenger

final class StreamAcceptBudgetTests: XCTestCase {

    func testAFirstImpressionGetsTheFullBudget() {
        // An open network must be untouched: the first attempt of every session, and every attempt
        // on a session where direct has not failed, gets the full 2.0s.
        XCTAssertEqual(
            StreamAcceptBudget.timeout(isFastUdp: false, usingVEIL: false, directAlreadyFailedThisSession: false),
            NetworkTiming.GRPC.streamOpenAcceptTimeout
        )
    }

    func testAfterDirectHasFailedTheLeashShortens() {
        // The whole of stage 2: a re-check, not a first impression, with VEIL under half a second
        // away.
        XCTAssertEqual(
            StreamAcceptBudget.timeout(isFastUdp: false, usingVEIL: false, directAlreadyFailedThisSession: true),
            NetworkTiming.GRPC.streamOpenAcceptTimeoutStandby
        )
        XCTAssertLessThan(
            NetworkTiming.GRPC.streamOpenAcceptTimeoutStandby,
            NetworkTiming.GRPC.streamOpenAcceptTimeout,
            "the short budget must actually be shorter, or this does nothing"
        )
    }

    // MARK: - What must NOT happen

    func testVEILKeepsItsLongBudgetEvenAfterDirectFailed() {
        // `directFailedThisSession` is why we are on VEIL at all, so it is true for every VEIL
        // open. Letting it shorten this budget would cut the relay to 0.8s — and a 6s cut is what
        // rotated healthy relays every cycle on RU networks in 2026-05.
        XCTAssertEqual(
            StreamAcceptBudget.timeout(isFastUdp: false, usingVEIL: true, directAlreadyFailedThisSession: true),
            NetworkTiming.GRPC.streamOpenAcceptTimeoutVEIL
        )
    }

    func testFastUdpKeepsItsOwnBudget() {
        // QUIC either answers well inside 1.5s or is not going to. Shortening it further buys
        // nothing and would fail paths that merely have high latency.
        for failed in [true, false] {
            XCTAssertEqual(
                StreamAcceptBudget.timeout(isFastUdp: true, usingVEIL: false, directAlreadyFailedThisSession: failed),
                NetworkTiming.GRPC.streamOpenAcceptTimeoutH3
            )
        }
    }

    func testTheBudgetsStayOrderedAsTheTiersIntend() {
        // A regression guard on the constants themselves: the comment that used to describe these
        // tiers said "H2 / VEIL → 6.0s" while the value had been 20s since 2026-05, and nothing
        // noticed for three months.
        XCTAssertLessThan(NetworkTiming.GRPC.streamOpenAcceptTimeoutStandby, NetworkTiming.GRPC.streamOpenAcceptTimeoutH3)
        XCTAssertLessThan(NetworkTiming.GRPC.streamOpenAcceptTimeoutH3, NetworkTiming.GRPC.streamOpenAcceptTimeout)
        XCTAssertLessThan(NetworkTiming.GRPC.streamOpenAcceptTimeout, NetworkTiming.GRPC.streamOpenAcceptTimeoutVEIL)
    }
}
