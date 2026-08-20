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

    // MARK: - The orphaned session an invite redeem brought back (2026-08-17)

    /// Redeeming an invite is the one chat-start that means "we are establishing a session now",
    /// so anything left from before is evidence of the past. On 2026-08-17 the peer had deleted
    /// the contact — no session on his side — while hers survived in the Keychain; the redeem
    /// restored it, `shouldPrewarm` saw a session and skipped, and her first message went out on
    /// a ratchet he had thrown away. It never arrived, and it read as delivered to her.
    ///
    /// Mutation: `return false` — the orphan is kept and the first message after every re-pairing
    /// is lost again.
    func testInviteRedeemRetiresWhateverSessionSurvived() {
        XCTAssertTrue(
            SessionReducer.chatStartRetiresExistingSession(origin: .inviteRedeem),
            "a session that outlived the pairing it belonged to cannot encrypt for the new one"
        )
    }

    /// The other direction, and the reason this is a question rather than an unconditional reset:
    /// opening a chat with a contact you already have must not touch its session. Tearing one down
    /// on every tap is the destructive re-init this whole suite exists to prevent.
    ///
    /// Mutation: `return true` — every chat opened re-handshakes, and in-flight messages break.
    func testOpeningAnExistingContactKeepsItsSession() {
        XCTAssertFalse(
            SessionReducer.chatStartRetiresExistingSession(origin: .existingContact),
            "the session of a contact you already have is the one to keep, not to retire"
        )
    }

    /// The distinction is the origin and nothing else — pinned so a third origin cannot be added
    /// and quietly inherit whichever answer happens to be the default.
    func testOnlyTheOriginDecidesIt() {
        XCTAssertNotEqual(
            SessionReducer.chatStartRetiresExistingSession(origin: .inviteRedeem),
            SessionReducer.chatStartRetiresExistingSession(origin: .existingContact)
        )
    }
}
