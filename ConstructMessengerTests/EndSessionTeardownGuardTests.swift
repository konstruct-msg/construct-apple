//
//  EndSessionTeardownGuardTests.swift
//  ConstructMessengerTests
//
//  The local teardown after a sent END_SESSION runs on the far side of a network round-trip, and
//  `archiveSession` destroys whatever session exists at that moment — not necessarily the one the
//  caller decided to end.
//
//  Observed 2026-08-02 on device, inside a single second:
//
//      Sending END_SESSION … (session_out_of_sync)     ← RPC leaves
//      Session initialized successfully, decrypted 42B ← a heal lands mid-flight
//      PQC: PQXDH Kyber SPK for 7574fdec…                with the PQ contribution applied
//      Session saved+verified (462B)
//      END_SESSION sent successfully: d32f756f         ← RPC returns
//      Archiving session … Removed session from Rust core   ← and destroys it
//
//  `clearArchivedSessions` follows the archive, so nothing was recoverable either. Flights of 3 s
//  were seen on the mobile path, so the window is wide.
//
//  Acceptance is mutation-based: make `shouldTearDownAfterEndSession` return `true`
//  unconditionally and testSessionReestablishedDuringFlight_IsKept must go red.
//

import XCTest
@testable import Construct_Messenger

final class EndSessionTeardownGuardTests: XCTestCase {

    // MARK: - The regression

    /// A session established while our END_SESSION was in flight is a different session, and it is
    /// healthy. Tearing it down throws away a working ratchet and leaves no archive.
    func testSessionReestablishedDuringFlight_IsKept() {
        XCTAssertFalse(
            SessionReducer.shouldTearDownAfterEndSession(condemned: 1_785_659_299, current: 1_785_659_301),
            "a newer establishedAt means the heal already replaced the condemned session — "
            + "the teardown belongs to a session that no longer exists"
        )
    }

    /// Nothing existed when we condemned, something does now: still a different session.
    func testSessionAppearedDuringFlight_IsKept() {
        XCTAssertFalse(
            SessionReducer.shouldTearDownAfterEndSession(condemned: nil, current: 1_785_659_301)
        )
    }

    // MARK: - The teardown must still happen in the ordinary case

    /// Unchanged stamp — the session we condemned is the session still there. Tear it down.
    func testUnchangedSession_IsTornDown() {
        XCTAssertTrue(
            SessionReducer.shouldTearDownAfterEndSession(condemned: 1_785_659_299, current: 1_785_659_299),
            "the guard must not become a blanket refusal — END_SESSION still has to end the session"
        )
    }

    /// No session either side (already gone, or never established): the archive+clear is a no-op,
    /// and running it is harmless and keeps the ordinary path unbranched.
    func testNoSessionEitherSide_ProceedsAsNoOp() {
        XCTAssertTrue(SessionReducer.shouldTearDownAfterEndSession(condemned: nil, current: nil))
    }

    /// Someone else already tore it down during the flight. The archive that now exists belongs to
    /// that path, not to us — `clearArchivedSessions` would destroy their recovery copy.
    func testTornDownByAnotherPathDuringFlight_WeDoNotClaimTheArchive() {
        XCTAssertFalse(
            SessionReducer.shouldTearDownAfterEndSession(condemned: 1_785_659_299, current: nil)
        )
    }

    // MARK: - Documented residual

    /// `establishedAt` is whole seconds, so a replacement established inside the same second as the
    /// condemned session is indistinguishable and the teardown proceeds. Pinned as a test so the
    /// limitation is a known property rather than a surprise: if this ever starts failing, someone
    /// gave the stamp finer granularity and the residual is gone.
    func testSameSecondReplacement_IsIndistinguishable() {
        XCTAssertTrue(
            SessionReducer.shouldTearDownAfterEndSession(condemned: 1_785_659_299, current: 1_785_659_299),
            "known residual — sub-second re-establishment is not detectable at this granularity"
        )
    }
}
