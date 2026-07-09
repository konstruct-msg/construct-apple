//
//  PrewarmRaceRegressionTests.swift
//  ConstructMessengerTests
//
//  Synthetic, deterministic repro + regression lock for the prewarm-vs-restore race
//  (see construct-docs/sessions/2026-06-16-prewarm-restore-race.md).
//
//  The bug: on launch, `prewarmSessions` could run before the orchestrator core was built
//  and sessions were restored from Keychain (e.g. when auth was delayed by a token refresh).
//  In that window `hasSession` returns false for EVERY peer, so prewarm concluded the
//  session was missing and sent a destructive END_SESSION + fresh re-init — discarding the
//  ratchet and breaking decryption of the peer's already-sent in-flight messages.
//
//  The natural repro requires a delayed-auth launch with an in-flight message and is hard to
//  reproduce on demand. So the fix is expressed as a pure decision —
//  `SessionReducer.shouldPrewarm(coreReady:isNaturalInitiator:sessionExistsOrRestorable:)` —
//  that `SessionCoordinator.prewarmSessions` filters through. These tests drive the race's
//  exact inputs (the `coreReady == false` window, and the "session sits in Keychain but isn't
//  loaded yet" case) and assert the fix suppresses the destructive prewarm. The *consequence*
//  of getting it wrong (an in-flight old-ratchet message becoming undecryptable after re-init)
//  is pinned separately by SessionEpochCharacterizationTests.
//

import XCTest
@testable import Construct_Messenger

final class PrewarmRaceRegressionTests: XCTestCase {

    // MARK: - The race window: core not ready ⇒ never prewarm

    /// THE regression lock. While the core is not ready, every peer reads as "no session";
    /// prewarm must be suppressed regardless of that (false) reading. If this ever returns
    /// true, the destructive startup END_SESSION storm is back.
    func testCoreNotReady_NeverPrewarms_EvenWhenSessionReadsMissing() {
        XCTAssertFalse(
            SessionReducer.shouldPrewarm(coreReady: false,
                                         isNaturalInitiator: true,
                                         sessionExistsOrRestorable: false),
            "Core-not-ready window must never prewarm — the 'missing' reading is unreliable here")
        // Even if a (stale) reading claimed a session, core-not-ready still suppresses.
        XCTAssertFalse(
            SessionReducer.shouldPrewarm(coreReady: false,
                                         isNaturalInitiator: true,
                                         sessionExistsOrRestorable: true))
        XCTAssertFalse(
            SessionReducer.shouldPrewarm(coreReady: false,
                                         isNaturalInitiator: false,
                                         sessionExistsOrRestorable: false))
    }

    // MARK: - Core ready: restore-aware decision

    /// Second half of the fix: a session that exists only in Keychain (restorable) must NOT be
    /// treated as missing — restoring it is correct, nuking it is the bug.
    func testCoreReady_RestorableSession_IsNotNuked() {
        XCTAssertFalse(
            SessionReducer.shouldPrewarm(coreReady: true,
                                         isNaturalInitiator: true,
                                         sessionExistsOrRestorable: true),
            "A restorable session must not be prewarmed (would destroy a healthy session)")
    }

    /// The genuinely-missing case prewarm exists for: core ready, we are the natural
    /// INITIATOR, and there is truly no session to restore.
    func testCoreReady_GenuinelyMissing_AsInitiator_DoesPrewarm() {
        XCTAssertTrue(
            SessionReducer.shouldPrewarm(coreReady: true,
                                         isNaturalInitiator: true,
                                         sessionExistsOrRestorable: false))
    }

    /// We never prewarm where we are the natural RESPONDER, even with no session — the
    /// INITIATOR drives establishment.
    func testCoreReady_Responder_NeverPrewarms() {
        XCTAssertFalse(
            SessionReducer.shouldPrewarm(coreReady: true,
                                         isNaturalInitiator: false,
                                         sessionExistsOrRestorable: false))
        XCTAssertFalse(
            SessionReducer.shouldPrewarm(coreReady: true,
                                         isNaturalInitiator: false,
                                         sessionExistsOrRestorable: true))
    }

    // MARK: - Full decision table (exhaustive)

    func testShouldPrewarm_ExhaustiveTruthTable() {
        // Only one input combination yields true: core ready + natural initiator + no session.
        for coreReady in [false, true] {
            for initiator in [false, true] {
                for hasOrRestorable in [false, true] {
                    let expected = coreReady && initiator && !hasOrRestorable
                    XCTAssertEqual(
                        SessionReducer.shouldPrewarm(coreReady: coreReady,
                                                     isNaturalInitiator: initiator,
                                                     sessionExistsOrRestorable: hasOrRestorable),
                        expected,
                        "shouldPrewarm(\(coreReady), \(initiator), \(hasOrRestorable)) should be \(expected)")
                }
            }
        }
    }
}
