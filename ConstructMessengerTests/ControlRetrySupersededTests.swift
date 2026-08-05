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

    private let announced = SessionEpoch(rawValue: "9c30bf14e7a26d85031fb4c78e29a6d0")!
    private let replacement = SessionEpoch(rawValue: "2ad86f05b13c94e7f60a2d38c5b71e94")!

    // MARK: - The regression

    /// The device case: a live session exists at retry time, but it is not the one we set out to
    /// announce. Sending anyway tells the peer to reset a session that already superseded ours.
    func testSessionReplacedBetweenAttempts_IsAbandoned() {
        XCTAssertFalse(
            SessionReducer.shouldContinueControlRetry(
                announced: announced, current: replacement, hasSession: true
            ),
            "attempt 3 must not speak for the session attempt 1 was created from"
        )
    }

    /// Torn down entirely between attempts — nothing left to announce.
    func testSessionGoneBetweenAttempts_IsAbandoned() {
        XCTAssertFalse(
            SessionReducer.shouldContinueControlRetry(
                announced: announced, current: nil, hasSession: false
            )
        )
    }

    /// A session appearing where we had none is still a different session: we were asked to
    /// announce nothing, and something else now owns this peer.
    func testSessionAppearedBetweenAttempts_IsAbandoned() {
        XCTAssertFalse(
            SessionReducer.shouldContinueControlRetry(
                announced: nil, current: replacement, hasSession: true
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
                announced: announced, current: announced, hasSession: false
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
                announced: announced, current: announced, hasSession: true
            )
        )
    }

    /// Neither side could name an epoch — the core is mid-restore, or this is a session from before
    /// the identifier was surfaced. That is not evidence of replacement, and `hasSession` says a
    /// session is live, so retry as before.
    func testNoEpochEitherSide_KeepsRetrying() {
        XCTAssertTrue(
            SessionReducer.shouldContinueControlRetry(
                announced: nil, current: nil, hasSession: true
            ),
            "absence of an epoch must not read as 'replaced' — that would disable retry whenever "
            + "the core cannot answer"
        )
    }

    // MARK: - The residual the epoch removed

    /// Under `establishedAt` (whole seconds, inherited from `shouldTearDownAfterEndSession`) a
    /// session replaced inside the same second read as unchanged and the retry proceeded — and the
    /// device incident this guard was written for unfolded inside one second.
    ///
    /// An epoch descends from the handshake, so the replacement is a different value however fast
    /// it arrives. The old residual test is inverted here.
    func testReplacementWithinTheSameSecond_IsNowDetected() {
        XCTAssertFalse(
            SessionReducer.shouldContinueControlRetry(
                announced: announced, current: replacement, hasSession: true
            ),
            "sub-second replacement is two epochs — the second-granularity residual is gone"
        )
    }

    // MARK: - A redelivered SESSION_RESET_INIT must be idempotent (build 579)

    /// The defect: `establishedAt` is stamped only when the re-init *completes*, so two copies of
    /// one redelivered SRI both read the pre-init value and both applied. The second archived the
    /// session the first had just built, and the payload that arrived in the gap asked the peer to
    /// start over. Real numbers from the 15:22:04 log line.
    func testRedeliveredResetInitIsCoalescedEvenWhileEstablishedLags() {
        let ts: UInt64 = 1_785_943_323
        let staleEstablished: UInt64 = 1_785_943_288

        // First copy: nothing applied yet → apply.
        XCTAssertFalse(SessionReducer.isResetInitSuperseded(
            establishedAt: staleEstablished, lastAppliedAt: nil, timestamp: ts, fudgeSeconds: 5
        ))
        // Second copy, same timestamp, establishment record has not caught up → must coalesce.
        XCTAssertTrue(SessionReducer.isResetInitSuperseded(
            establishedAt: staleEstablished, lastAppliedAt: ts, timestamp: ts, fudgeSeconds: 5
        ), "a redelivery of the init we just applied must not re-establish")
    }

    /// A genuine peer retry re-stamps its timestamp, so it is strictly newer and still applies —
    /// dropping it is the 2026-07-26 stranding bug, which this must not reintroduce.
    func testGenuinePeerRetryWithNewerTimestampStillApplies() {
        XCTAssertFalse(SessionReducer.isResetInitSuperseded(
            establishedAt: 1_785_943_324,
            lastAppliedAt: 1_785_943_323,
            timestamp: 1_785_943_340,
            fudgeSeconds: 5
        ))
    }

    /// An init older than the one we acted on is a backlog replay, whatever the establishment says.
    func testOlderInitThanTheOneWeAppliedIsCoalesced() {
        XCTAssertTrue(SessionReducer.isResetInitSuperseded(
            establishedAt: nil, lastAppliedAt: 1_785_943_323, timestamp: 1_785_943_300, fudgeSeconds: 5
        ))
    }

    /// With no memory yet and no establishment record, an init is always applied — never strand a
    /// possibly-live re-init on a missing record.
    func testNoMemoryNoRecordAlwaysApplies() {
        XCTAssertFalse(SessionReducer.isResetInitSuperseded(
            establishedAt: nil, lastAppliedAt: nil, timestamp: 1_785_943_323, fudgeSeconds: 5
        ))
    }
}
