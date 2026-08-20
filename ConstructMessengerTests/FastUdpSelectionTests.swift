//
//  FastUdpSelectionTests.swift
//  ConstructMessengerTests
//
//  The transport choice, after the machinery that used to make it was deleted.
//
//  Until 2026-08-11 this decision read a consecutive-failure counter, a ladder rung, a suppression
//  window, a per-network record persisted under a salted fingerprint, and a once-per-launch
//  restore. Each of the five had a bug fixed between 2026-08-08 and 2026-08-11; the last two were
//  written to fix the first three. decisions/no-client-side-network-learning replaced all of it
//  with: probe once per session, once per network change, and remember nothing.
//

import XCTest
@testable import Construct_Messenger

final class FastUdpSelectionTests: XCTestCase {

    private func select(h3: Bool = true, quic: Bool = true, oneShot: Bool = false, failed: Bool = false) -> Bool {
        FastUdpSelection.useH2Fallback(
            h3Enabled: h3, experimentalQuic: quic, oneShotFallback: oneShot, failedThisSession: failed
        )
    }

    func testAFreshSessionProbesFastUdp() {
        // The paradigm in one assertion: assume the network works.
        XCTAssertFalse(select(), "a session with no evidence must try the fast path")
    }

    func testOneFailureIsEnoughForTheRestOfTheSession() {
        // Not a rung, not a window, not a persisted record — one bit, and it lasts exactly as long
        // as the process does.
        XCTAssertTrue(select(failed: true))
    }

    func testTheOneShotFallbackIsHonouredIndependently() {
        // `shouldFallbackToH2Direct` is the previous attempt asking for H2 on the *next* open. It
        // is consumed by the caller, so it must not need the session bit to be set.
        XCTAssertTrue(select(oneShot: true, failed: false))
    }

    // MARK: - What must NOT happen

    func testNoFastCarrierMeansH2RegardlessOfEvidence() {
        // With both flags off there is nothing to select; the session bit must not be able to
        // produce an H3 attempt that the flags forbid.
        for failed in [true, false] {
            for oneShot in [true, false] {
                XCTAssertTrue(
                    select(h3: false, quic: false, oneShot: oneShot, failed: failed),
                    "flags off must always mean H2"
                )
            }
        }
    }

    func testEitherFlagAloneKeepsTheFastPathAvailable() {
        // engine-QUIC reuses the H3 slot; disabling native H3 alone must not disable it.
        XCTAssertFalse(select(h3: false, quic: true))
        XCTAssertFalse(select(h3: true, quic: false))
    }

    func testTheDecisionHasNoMemoryOfItsOwn() {
        // The point of the deletion. Calling it repeatedly with a clean session must never drift
        // toward H2 — the previous design accumulated exactly that, in five places.
        for _ in 0..<50 {
            XCTAssertFalse(select())
        }
    }
}
