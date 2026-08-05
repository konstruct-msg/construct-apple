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
    ///
    /// The first remedy compared timestamps too (`lastAppliedAt`), which worked only because a peer
    /// retry happens to re-stamp. This asks the question directly: is it the same init?
    func testRedeliveredResetInitIsCoalescedEvenWhileEstablishedLags() {
        let ts: UInt64 = 1_785_943_323
        let staleEstablished: UInt64 = 1_785_943_288

        // First copy: this init has not been applied → apply.
        XCTAssertFalse(SessionReducer.isResetInitSuperseded(
            alreadyApplied: false, establishedAt: staleEstablished, timestamp: ts, fudgeSeconds: 5
        ))
        // Second copy, same init, establishment record has not caught up → must coalesce.
        XCTAssertTrue(SessionReducer.isResetInitSuperseded(
            alreadyApplied: true, establishedAt: staleEstablished, timestamp: ts, fudgeSeconds: 5
        ), "a redelivery of the init we just applied must not re-establish")
    }

    /// A genuine peer retry is a *different* init — new ephemeral key — so it applies even though
    /// its predecessor is on record. Dropping it is the 2026-07-26 stranding bug, which this must
    /// not reintroduce.
    func testGenuinePeerRetryIsADifferentInitAndStillApplies() {
        XCTAssertFalse(SessionReducer.isResetInitSuperseded(
            alreadyApplied: false,
            establishedAt: 1_785_943_324,
            timestamp: 1_785_943_340,
            fudgeSeconds: 5
        ))
    }

    /// An init we already acted on is coalesced whatever the establishment record says — including
    /// when there is none. This is the case a timestamp could not reach: the record lags precisely
    /// when the duplicate arrives.
    func testAlreadyAppliedInitIsCoalescedWithNoEstablishmentRecord() {
        XCTAssertTrue(SessionReducer.isResetInitSuperseded(
            alreadyApplied: true, establishedAt: nil, timestamp: 1_785_943_300, fudgeSeconds: 5
        ))
    }

    /// With nothing applied and no establishment record, an init is always applied — never strand a
    /// possibly-live re-init on a missing record.
    func testNoMemoryNoRecordAlwaysApplies() {
        XCTAssertFalse(SessionReducer.isResetInitSuperseded(
            alreadyApplied: false, establishedAt: nil, timestamp: 1_785_943_323, fudgeSeconds: 5
        ))
    }

    /// The half the ephemeral key cannot answer: an init we have *never* applied, pre-dating the
    /// session we now hold, is a server backlog replay. There is no pre-decryption ordering
    /// primitive but the peer clock, so this comparison keeps its fudge.
    func testNeverAppliedInitPredatingEstablishmentIsCoalesced() {
        XCTAssertTrue(SessionReducer.isResetInitSuperseded(
            alreadyApplied: false,
            establishedAt: 1_785_943_324,
            timestamp: 1_785_943_300,
            fudgeSeconds: 5
        ))
    }

    // MARK: - The ledger that answers `alreadyApplied`

    /// Two copies of one init carry one ephemeral key; that is the whole mechanism.
    func testLedgerRecognisesTheSameInit() {
        var ledger = AppliedInitLedger()
        let ephemeral = Data(repeating: 0xA7, count: 32)
        XCTAssertFalse(ledger.contains(ephemeral))
        ledger.record(ephemeral)
        XCTAssertTrue(ledger.contains(ephemeral))
        XCTAssertFalse(ledger.contains(Data(repeating: 0xB3, count: 32)), "a different init is a different key")
    }

    /// An init we cannot identify must not be coalesced on a guess: a redundant re-init is cheap,
    /// a dropped live one strands the peer permanently.
    func testLedgerNeverMatchesAnUnidentifiableInit() {
        var ledger = AppliedInitLedger()
        ledger.record(Data())
        XCTAssertFalse(ledger.contains(Data()))
    }

    /// Bounded, most-recent-first. The oldest init falls out rather than the ledger growing per peer.
    func testLedgerEvictsTheOldestBeyondCapacity() {
        var ledger = AppliedInitLedger()
        let keys = (0...AppliedInitLedger.capacity).map { Data([UInt8($0)]) }
        keys.forEach { ledger.record($0) }
        XCTAssertFalse(ledger.contains(keys[0]), "the oldest init is evicted")
        XCTAssertTrue(ledger.contains(keys[1]))
        XCTAssertTrue(ledger.contains(keys.last!))
    }

    /// A peer retrying one init must not be able to push the others out — re-recording moves the
    /// key to the front instead of adding a copy. Without this, a redelivery loop would evict the
    /// ledger and make every earlier init look fresh again.
    func testRerecordingDoesNotEvictOtherInits() {
        var ledger = AppliedInitLedger()
        let first = Data([0x01])
        ledger.record(first)
        let others = (2...AppliedInitLedger.capacity).map { Data([UInt8($0)]) }
        others.forEach { ledger.record($0) }
        for _ in 0..<20 { ledger.record(others.last!) }
        XCTAssertTrue(ledger.contains(first), "re-recording one init must not evict the rest")
    }
}
