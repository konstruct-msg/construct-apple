//
//  ControlRetrySupersededTests.swift
//  ConstructMessengerTests
//
//  A handshake-control retry crosses the network, and a session can be replaced underneath it.
//  Observed on device 2026-08-04, over four seconds:
//
//      14:40:48  sri_fail attempt 1/3: StealthDowngradeBlocked
//      14:40:49  sri_fail attempt 2/3: StealthDowngradeBlocked
//      14:40:51  SESSION_RESET_INIT from peer → our session archived, RESPONDER init  ← replaced
//      14:40:52  sri_sent (attempt 3)                                                 ← announces
//                                                                                       a session
//                                                                                       gone 1 s
//      14:40:56  peer: «No session but messageNumber=2 — requesting END_SESSION»
//
//  `sendSessionControlCore` checked `hasSession` once, before the retry loop — and that was true
//  the whole time, because a *different* session existed by attempt 3. The peer read the retry as
//  "reset", tore down a healthy ratchet, and the cascade ended in a lost user message.
//
//  Same defect and same remedy as `shouldTearDownAfterEndSession` (see EndSessionTeardownGuardTests):
//  identify the session the decision was made about, don't assert that one exists.
//
//  Acceptance is mutation-based: make `shouldContinueControlRetry` return `hasSession` and
//  testSessionReplacedBetweenAttempts_IsAbandoned must go red.
//

import XCTest
@testable import Construct_Messenger

final class ControlRetrySupersededTests: XCTestCase {

    // MARK: - The regression

    /// The device case: a live session exists at retry time, but it is not the one we set out to
    /// announce. Sending anyway tells the peer to reset a session that already superseded ours.
    func testSessionReplacedBetweenAttempts_IsAbandoned() {
        XCTAssertFalse(
            SessionReducer.shouldContinueControlRetry(
                announced: 1_785_854_448, current: 1_785_854_451, hasSession: true
            ),
            "attempt 3 must not speak for the session attempt 1 was created from"
        )
    }

    /// Torn down entirely between attempts — nothing left to announce.
    func testSessionGoneBetweenAttempts_IsAbandoned() {
        XCTAssertFalse(
            SessionReducer.shouldContinueControlRetry(
                announced: 1_785_854_448, current: nil, hasSession: false
            )
        )
    }

    /// A session appearing where we had none is still a different session: we were asked to
    /// announce nothing, and something else now owns this peer.
    func testSessionAppearedBetweenAttempts_IsAbandoned() {
        XCTAssertFalse(
            SessionReducer.shouldContinueControlRetry(
                announced: nil, current: 1_785_854_451, hasSession: true
            )
        )
    }

    /// `hasSession` is not sufficient on its own — that is the exact false reassurance the old
    /// pre-loop guard gave. Matching stamps with no live session is still an abandon.
    ///
    /// Mutation: `return announced == current` (drop the hasSession guard).
    func testMatchingStampsWithNoLiveSession_IsAbandoned() {
        XCTAssertFalse(
            SessionReducer.shouldContinueControlRetry(
                announced: 1_785_854_448, current: 1_785_854_448, hasSession: false
            ),
            "a stale in-memory/Keychain stamp must not resurrect a retry for a dead session"
        )
    }

    // MARK: - Retries must still happen in the ordinary case

    /// The whole point of the retry loop: a transient send failure (StealthDowngradeBlocked,
    /// network) on an unchanged session must be retried, not abandoned.
    ///
    /// Mutation: `return false` — this test is what stops the guard becoming a blanket refusal
    /// that silently disables SRI retry and re-opens the deadlock the watchdog was built for.
    func testUnchangedSession_KeepsRetrying() {
        XCTAssertTrue(
            SessionReducer.shouldContinueControlRetry(
                announced: 1_785_854_448, current: 1_785_854_448, hasSession: true
            )
        )
    }

    /// A session that never had a stamp on either side (older builds never persisted them) is not
    /// evidence of replacement — retry, as before.
    func testNoStampEitherSide_KeepsRetrying() {
        XCTAssertTrue(
            SessionReducer.shouldContinueControlRetry(
                announced: nil, current: nil, hasSession: true
            ),
            "absence of a stamp must not read as 'replaced' — that would disable retry on any "
            + "session predating establishedAt persistence"
        )
    }

    // MARK: - The known residual, pinned so it is a decision and not a surprise

    /// `establishedAt` is whole seconds, inherited from `shouldTearDownAfterEndSession`. A session
    /// replaced inside the same second reads as unchanged and the retry proceeds. Narrower than
    /// the unconditional retry it replaces, but not zero — recorded here so a future
    /// sub-second stamp has a test that says what it fixes.
    func testReplacementWithinTheSameSecond_IsNotDetected() {
        XCTAssertTrue(
            SessionReducer.shouldContinueControlRetry(
                announced: 1_785_854_451, current: 1_785_854_451, hasSession: true
            ),
            "known residual: second-granularity stamps cannot separate these"
        )
    }
}
