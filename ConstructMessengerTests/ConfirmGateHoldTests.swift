//
//  ConfirmGateHoldTests.swift
//  ConstructMessengerTests
//
//  A user's message was destroyed on 2026-08-04 by the tie-break confirm gate, in two steps one
//  second apart. Device A had just re-inited and sent its new session's init ping followed by the
//  queued message; device B held the gate up:
//
//      A 14:40:58  init ping  msgNum=0 → b0ce8c39
//      A 14:40:58  «Привет»   msgNum=1 → da7a099a
//      B 14:40:58  stale_init_drop: discarding stale msgNum=0 (tie-break WIN)   ← head discarded
//      B 14:40:58  ORCH actions=end_session → «DR diverged» → END_SESSION       ← tail killed it
//
//  The gate discarded the *head* of A's handshake as stale — but A's init was one second old, not
//  stale — and the *tail* of that same handshake was not gated at all, so it went to the ratchet,
//  failed, and tore the session down. `markProcessed` on the head meant the server never
//  redelivered it. A showed `sent` forever; B never rendered the message.
//
//  Acceptance is mutation-based. Each test below names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class ConfirmGateHoldTests: XCTestCase {

    // MARK: - The regression: nothing behind the gate may be discarded

    /// The head. A peer msgNum=0 inside our confirm window is held, not discarded — we cannot yet
    /// tell a superseded init from a live one, and only one of those two guesses is recoverable.
    ///
    /// Mutation: return `.route` for `isPeerInit`.
    func testPeerInitInsideTheWindowIsHeld() {
        XCTAssertEqual(
            SessionReducer.confirmGateAction(
                isPending: true, isControlCarrier: false, isPeerInit: true, decryptFailed: false
            ),
            .hold,
            "the peer may have genuinely re-inited one second ago — that is indistinguishable "
            + "from a stale init until the gate falls"
        )
    }

    /// The tail, and the actual loss. The core says `sendEndSession`; inside our own confirm
    /// window that is the expected consequence of the session *we* replaced, not evidence the
    /// ratchet diverged. Tearing down here answers our own reset with another reset.
    ///
    /// Mutation: return `.route` for `decryptFailed`.
    func testDecryptFailureInsideTheWindowIsHeldNotTornDown() {
        XCTAssertEqual(
            SessionReducer.confirmGateAction(
                isPending: true, isControlCarrier: false, isPeerInit: false, decryptFailed: true
            ),
            .hold,
            "this is the line the lost «Привет» died on — msgNum=1 of a handshake whose msgNum=0 "
            + "had just been discarded"
        )
    }

    /// Head and tail are the same handshake, so they must get the same answer. The defect was
    /// precisely that one was gated and the other was not.
    func testHeadAndTailOfTheSameHandshakeAgree() {
        let head = SessionReducer.confirmGateAction(
            isPending: true, isControlCarrier: false, isPeerInit: true, decryptFailed: false
        )
        let tail = SessionReducer.confirmGateAction(
            isPending: true, isControlCarrier: false, isPeerInit: false, decryptFailed: true
        )
        XCTAssertEqual(head, tail, "gating only the init guarantees its follow-up cannot decrypt")
    }

    // MARK: - The gate must not swallow the traffic that resolves it

    /// END_SESSION / SESSION_RESET_INIT drive the convergence the gate is waiting for. Holding
    /// them would make the gate wait on itself for the full 75 s window.
    ///
    /// Mutation: drop `!isControlCarrier` from the guard.
    func testControlCarriersAreNeverHeld() {
        XCTAssertEqual(
            SessionReducer.confirmGateAction(
                isPending: true, isControlCarrier: true, isPeerInit: true, decryptFailed: false
            ),
            .route
        )
        XCTAssertEqual(
            SessionReducer.confirmGateAction(
                isPending: true, isControlCarrier: true, isPeerInit: false, decryptFailed: true
            ),
            .route
        )
    }

    // MARK: - The gate must stay narrow

    /// Gate down: everything routes. The hold is a consequence of *our* pending re-init and must
    /// not become a blanket buffer on the receive path.
    ///
    /// Mutation: drop `isPending` from the guard.
    func testGateDownRoutesEverything() {
        for peerInit in [true, false] {
            for failed in [true, false] {
                XCTAssertEqual(
                    SessionReducer.confirmGateAction(
                        isPending: false, isControlCarrier: false,
                        isPeerInit: peerInit, decryptFailed: failed
                    ),
                    .route,
                    "isPeerInit=\(peerInit) decryptFailed=\(failed) must route with no gate"
                )
            }
        }
    }

    /// Gate up but the message decrypted fine and is not an init — ordinary mid-ratchet traffic
    /// the peer sent after accepting our SRI, arriving before its `session_ready`. Routing it is
    /// what keeps the hold from costing latency on the happy path.
    ///
    /// Mutation: return `.hold` unconditionally once `isPending`.
    func testDecryptableTrafficInsideTheWindowStillRoutes() {
        XCTAssertEqual(
            SessionReducer.confirmGateAction(
                isPending: true, isControlCarrier: false, isPeerInit: false, decryptFailed: false
            ),
            .route,
            "a message that decrypted needs no hold — the peer is already on our new session"
        )
    }

    // MARK: - The hold must be bounded and replayable

    /// The buffer the hold writes into is the same per-peer queue the session-init path uses, so
    /// its cap is what bounds the hold. Beyond it a message really is dropped — the one branch in
    /// the path that must stay loud (`confirmHoldOverflow`).
    @MainActor
    func testHoldBufferAcceptsUntilItsCapThenRefuses() {
        let queue = PendingSessionQueue()
        let peer = "7574fdec-ca31-44ac-9d43-0e6e870fe4d5"
        var accepted = 0
        for i in 0..<120 where queue.enqueue(Self.message(id: "m\(i)"), for: peer) {
            accepted += 1
        }
        XCTAssertEqual(accepted, 100, "the cap is what makes the hold bounded rather than a leak")
        XCTAssertFalse(
            queue.enqueue(Self.message(id: "overflow"), for: peer),
            "refusal is what the ERROR + confirmHoldOverflow branch keys off"
        )
    }

    /// A replay drains: the same message cannot be replayed twice, and the peer's buffer is empty
    /// afterwards. Without this the gate would re-hold on every release and read like a flush.
    @MainActor
    func testReplayDrainsTheBuffer() {
        let queue = PendingSessionQueue()
        let peer = "7574fdec-ca31-44ac-9d43-0e6e870fe4d5"
        queue.enqueue(Self.message(id: "head"), for: peer)
        queue.enqueue(Self.message(id: "tail"), for: peer)

        let replayed = queue.drain(for: peer)

        XCTAssertEqual(replayed.map(\.id), ["head", "tail"], "order is the ratchet's order")
        XCTAssertEqual(queue.count(for: peer), 0)
        XCTAssertTrue(queue.drain(for: peer).isEmpty, "a second release must not re-deliver")
    }

    /// Holds are per-peer: a gate up for one contact must not delay another's traffic.
    @MainActor
    func testHoldsAreIndependentPerPeer() {
        let queue = PendingSessionQueue()
        queue.enqueue(Self.message(id: "a"), for: "peer-a")
        queue.enqueue(Self.message(id: "b"), for: "peer-b")

        XCTAssertEqual(queue.drain(for: "peer-a").map(\.id), ["a"])
        XCTAssertEqual(queue.count(for: "peer-b"), 1, "draining one peer must not touch another")
    }

    // MARK: - Helpers

    private static func message(id: String) -> ChatMessage {
        ChatMessage(
            id: id,
            from: "7574fdec-ca31-44ac-9d43-0e6e870fe4d5",
            to: "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167",
            ephemeralPublicKey: Data(),
            messageNumber: 0,
            content: Data(),
            suiteId: 0,
            timestamp: 1_785_854_458
        )
    }

    // MARK: - Every path that drops the gate must settle the hold

    /// The lazy TTL inside `isPending` releases the gate from inside a *query*, so it cannot replay
    /// what it released — and it beats the 30 s watchdog to the entry, which is why the `.giveUp`
    /// replay never ran. Build 575, 2026-08-04: `confirm_hold` 2, `confirm_replay` 0, the cursor
    /// deferred behind both. The lapse must therefore be claimable exactly once by whoever can.
    ///
    /// Mutation: drop the `lapsedUnreplayed.insert(userId)` from the expiry branch.
    @MainActor
    func testLazyExpiryLeavesAClaimableLapse() {
        let tracker = SessionConfirmationTracker.shared
        let peer = "lapse-peer-\(UUID().uuidString)"
        tracker.markPending(peer)

        // Not yet expired: nothing to settle.
        XCTAssertTrue(tracker.isPending(peer))
        XCTAssertFalse(tracker.consumeLapse(peer), "an unexpired gate has no lapse to claim")

        tracker.expireForTesting(peer)
        XCTAssertFalse(tracker.isPending(peer), "the TTL must still self-release — no deadlock")
        XCTAssertTrue(tracker.consumeLapse(peer), "the release left a hold nobody replayed")
        XCTAssertFalse(tracker.consumeLapse(peer), "claimed once, so two callers cannot both replay")
    }

    /// The explicit releases replay as part of dropping the gate, so they must NOT also leave a
    /// lapse — a second replay would re-route messages the first one already handled.
    ///
    /// Mutation: remove `lapsedUnreplayed.remove(userId)` from `markConfirmed`.
    @MainActor
    func testExplicitReleasesLeaveNothingToSettle() {
        let tracker = SessionConfirmationTracker.shared

        let confirmed = "confirmed-peer-\(UUID().uuidString)"
        tracker.markPending(confirmed)
        tracker.markConfirmed(confirmed)
        XCTAssertFalse(tracker.consumeLapse(confirmed), "the peer-ack path replays the hold itself")

        let lapsed = "watchdog-peer-\(UUID().uuidString)"
        tracker.markPending(lapsed)
        tracker.releaseLapsed(lapsed)
        XCTAssertFalse(tracker.consumeLapse(lapsed), "the watchdog give-up path replays it itself")
    }

    /// A lapse recorded by the TTL, then superseded by an explicit confirm, must not survive: the
    /// confirm's own replay already drained the buffer.
    @MainActor
    func testConfirmAfterLapseDoesNotLeaveADoubleReplay() {
        let tracker = SessionConfirmationTracker.shared
        let peer = "raced-peer-\(UUID().uuidString)"
        tracker.markPending(peer)
        tracker.expireForTesting(peer)
        _ = tracker.isPending(peer)          // records the lapse
        tracker.markConfirmed(peer)          // peer ack lands late and replays
        XCTAssertFalse(tracker.consumeLapse(peer), "one release, one replay")
    }

    // MARK: - Not covered here, on purpose
    //
    // That a held message is never `markProcessed`'d — the property that turned this delay into a
    // permanent loss — is asserted by construction (`holdUntilConfirmResolves` has no ACK call)
    // and not by a test: reaching it means standing up MessageRouter with CryptoManager, Core Data
    // and three singletons, and a test that cannot fail against a mutation is worse than none
    // (decisions/ios-semantic-divergence-signals, amendment 2026-08-04). The device-log check is
    // `grep confirm_hold` with no matching `Skipping already-processed` for the same id.
}
