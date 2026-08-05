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
//  2026-08-05: the identity compared here changed from `establishedAt` (whole seconds) to
//  `SessionEpoch` (derived from the handshake). The guard is unchanged; what it compares is now
//  exact. See `decisions/session-epoch-before-mls.md`.
//
//  Acceptance is mutation-based: make `shouldTearDownAfterEndSession` return `true`
//  unconditionally and testSessionReestablishedDuringFlight_IsKept must go red.
//

import XCTest
@testable import Construct_Messenger

final class EndSessionTeardownGuardTests: XCTestCase {

    private let condemned = SessionEpoch(rawValue: "4f2a91c7d0e35b8a6c1f47e29b03da58")!
    private let replacement = SessionEpoch(rawValue: "b7e10c34a95d2f68e04b7c19d3f8a260")!

    // MARK: - The regression

    /// A session established while our END_SESSION was in flight is a different session, and it is
    /// healthy. Tearing it down throws away a working ratchet and leaves no archive.
    func testSessionReestablishedDuringFlight_IsKept() {
        XCTAssertFalse(
            SessionReducer.shouldTearDownAfterEndSession(condemned: condemned, current: replacement),
            "a different epoch means the heal already replaced the condemned session — "
            + "the teardown belongs to a session that no longer exists"
        )
    }

    /// Nothing existed when we condemned, something does now: still a different session.
    func testSessionAppearedDuringFlight_IsKept() {
        XCTAssertFalse(
            SessionReducer.shouldTearDownAfterEndSession(condemned: nil, current: replacement)
        )
    }

    // MARK: - The teardown must still happen in the ordinary case

    /// Unchanged epoch — the session we condemned is the session still there. Tear it down.
    func testUnchangedSession_IsTornDown() {
        XCTAssertTrue(
            SessionReducer.shouldTearDownAfterEndSession(condemned: condemned, current: condemned),
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
            SessionReducer.shouldTearDownAfterEndSession(condemned: condemned, current: nil)
        )
    }

    // MARK: - The residual the epoch removed

    /// Under `establishedAt` this was the documented hole: whole seconds, so a replacement
    /// established inside the same second as the condemned session read as identical and the
    /// teardown proceeded. The observed incident above happened *inside one second*, so the hole
    /// covered the very case the guard was written for.
    ///
    /// An epoch descends from the X3DH root key, not from the clock, so two establishments are
    /// different however close together they are. This test is the old residual inverted: it asserts
    /// the sub-second replacement is now detected.
    func testSameInstantReplacement_IsNowDistinguishable() {
        XCTAssertFalse(
            SessionReducer.shouldTearDownAfterEndSession(condemned: condemned, current: replacement),
            "two establishments a millisecond apart are two epochs — the whole-second residual is gone"
        )
    }

    /// The identity must be the epoch's own value, not object identity or a prefix: two sessions
    /// whose identifiers share a prefix are still different sessions.
    func testEpochsSharingAPrefix_AreDifferentSessions() {
        let a = SessionEpoch(rawValue: "4f2a91c7d0e35b8a6c1f47e29b03da58")!
        let b = SessionEpoch(rawValue: "4f2a91c7d0e35b8a6c1f47e29b03da59")!
        XCTAssertFalse(SessionReducer.shouldTearDownAfterEndSession(condemned: a, current: b))
    }

    /// An empty identifier is not an epoch. Were it allowed, two sessions the core could not
    /// identify would compare equal to each other and a teardown would proceed on the strength of
    /// a shared absence.
    func testEmptyIdentifierIsNotAnEpoch() {
        XCTAssertNil(SessionEpoch(rawValue: ""))
    }
}
