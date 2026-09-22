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
//  On 2026-08-21 the same predicate cost 19 more. By then the gate held `messageNumber == 0`
//  instead of discarding it, so nothing was lost at the hold — but the type of a `session_ready`
//  had moved inside the ciphertext (2026-08-03), which left it looking like every other fresh
//  chain restart. The gate buffered 16 of the peer's 19 acknowledgements, i.e. the only thing that
//  could release it, and the tie-break watchdog's next re-init then superseded the whole buffer:
//
//      A 07:30:55  session_ready → b9161496  (msgNum=0, ct hidden in KNST byte 5)
//      B 07:30:56  confirm_hold: holding msgNum=0 (peer_init) — buffer 1      ← the key, held
//      B 07:31:25  tie_break_watchdog: no ack — re-sending SESSION_RESET_INIT ← epoch moves
//      B 07:32:11  confirm_replay: 3 re-routed, 3 superseded of 6 held        ← and dropped
//
//  27 messages held across the run, 0 ever saved. The hold before decryption is gone; decryption
//  is the test the predicate was approximating.
//
//  Acceptance is mutation-based. Each test below names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class ConfirmGateHoldTests: XCTestCase {

    // MARK: - The regression: nothing behind the gate may be discarded

    /// The loss. The core says `sendEndSession`; inside our own confirm window that is the expected
    /// consequence of the session *we* replaced, not evidence the ratchet diverged. Tearing down
    /// here answers our own reset with another reset.
    ///
    /// Mutation: return `.route` once `isPending`.
    func testDecryptFailureInsideTheWindowIsHeldNotTornDown() {
        XCTAssertEqual(
            SessionReducer.confirmGateAction(isPending: true, isControlCarrier: false),
            .hold,
            "this is the line the lost «Привет» died on — msgNum=1 of a handshake whose msgNum=0 "
            + "had just been discarded"
        )
    }

    // MARK: - The gate must not swallow the traffic that resolves it

    /// END_SESSION / SESSION_RESET_INIT drive the convergence the gate is waiting for. Holding
    /// them would make the gate wait on itself for the full 75 s window.
    ///
    /// Mutation: drop `!isControlCarrier` from the guard.
    func testControlCarriersAreNeverHeld() {
        XCTAssertEqual(
            SessionReducer.confirmGateAction(isPending: true, isControlCarrier: true),
            .route
        )
    }

    // MARK: - The gate must stay narrow

    /// Gate down: everything routes. The hold is a consequence of *our* pending re-init and must
    /// not become a blanket buffer on the receive path.
    ///
    /// Mutation: drop `isPending` from the guard.
    func testGateDownRoutesEverything() {
        for carrier in [true, false] {
            XCTAssertEqual(
                SessionReducer.confirmGateAction(isPending: false, isControlCarrier: carrier),
                .route,
                "isControlCarrier=\(carrier) must route with no gate"
            )
        }
    }

    // MARK: - 2026-08-21: the gate held its own key

    /// The envelope of the peer's `session_ready` — the message that closes the gate. Its type
    /// lives in KNST byte 5 inside the ciphertext (2026-08-03), so at the envelope it is a plain
    /// `messageNumber == 0` with no handshake evidence whatever, exactly like the first send of
    /// any fresh DH chain.
    ///
    /// This is the fixture the removed pre-decryption hold could not tell from a peer init. Sixteen
    /// of the peer's nineteen acknowledgements went into the buffer of the gate waiting for them.
    private static func sessionReadyShapedEnvelope() -> ChatMessage {
        ChatMessage(
            id: "b9161496-a841-4d94-b5ab-aaf1090b4a76",
            from: "7574fdec-ca31-44ac-9d43-0e6e870fe4d5",
            to: "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8",
            ephemeralPublicKey: Data(repeating: 0x05, count: 32),
            messageNumber: 0,
            content: Data(repeating: 0x79, count: 283),
            suiteId: 3,
            timestamp: 1_787_297_455
        )
    }

    /// The predicate the hold used, applied to that envelope, against the predicate that replaced
    /// it. `messageNumber == 0` is not a handshake, and the classifier is the only thing allowed to
    /// answer the question.
    ///
    /// Mutation: make `receivingInitKind` return `.handshake` for `oneTimePreKeyId == 0 &&
    /// kemCiphertextBytes == 0 && pqMessageEpoch > 0`.
    func testTheAcknowledgementIsNotAHandshakeByTheClassifier() {
        let envelope = Self.sessionReadyShapedEnvelope()
        XCTAssertEqual(envelope.messageNumber, 0, "the old predicate fired on exactly this")

        XCTAssertEqual(
            SessionReducer.receivingInitKind(
                messageNumber: envelope.messageNumber,
                oneTimePreKeyId: envelope.oneTimePreKeyId,
                kemCiphertextBytes: envelope.kemCiphertext.count,
                pqMessageEpoch: 4,               // a live PQ ratchet stamps one; a fresh session does not
                isSessionResetInit: envelope.isSessionResetInit
            ),
            .midSessionLeftover,
            "no consumed OTPK, no KEM ciphertext and a non-zero PQ epoch is a live chain restarting"
        )
    }

    /// The consequence at replay: with the classifier's verdict, the acknowledgement is re-routed
    /// rather than acknowledged-and-dropped. Under `messageNumber == 0` this returned `.superseded`
    /// — 19 times in the 2026-08-21 run, each one final.
    ///
    /// Mutation: change the `kind == .handshake` guard to `kind != .midRatchet`.
    func testAFreshChainRestartIsReplayedNotSuperseded() {
        XCTAssertEqual(
            SessionReducer.heldReplayDisposition(
                heldAgainst: Self.heldAgainst,
                current: Self.replacement,
                kind: .midSessionLeftover
            ),
            .replay,
            "the epoch moved, but this is not a handshake, so it is not this branch's to drop"
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

    /// A teardown or SESSION_RESET_INIT from one device of the account drops what *that* device
    /// queued and leaves the sibling's handshake for the bundle fetch already in flight. Stand,
    /// 2026-09-22: C's reset made A and B each send an init; the second cleared the account
    /// queue, the responder plan ran with one carrier, and A re-sent its init every thirty
    /// seconds, a one-time pre-key each, for a session C had never been asked to open.
    ///
    /// Mutation: make `remove(for:device:)` clear the account — this reddens.
    @MainActor
    func testARemovalNamedForOneDeviceKeepsTheSiblingsHandshake() {
        let queue = PendingSessionQueue()
        let peer = "7574fdec-ca31-44ac-9d43-0e6e870fe4d5"
        queue.enqueue(Self.message(id: "b-init", device: "b814c8ab96bc4496b80795fa256eed9f"), for: peer)
        queue.enqueue(Self.message(id: "a-init", device: "c6bfaaefcdd4e6cac587d22c69129d6e"), for: peer)
        queue.enqueue(Self.message(id: "unnamed"), for: peer)

        queue.remove(for: peer, device: "c6bfaaefcdd4e6cac587d22c69129d6e")

        XCTAssertEqual(queue.messages(for: peer).map(\.id), ["b-init"],
                       "the sibling's init stays; the unattributable one goes with the named device's")
        queue.remove(for: peer, device: nil)
        XCTAssertEqual(queue.count(for: peer), 0, "no device named clears the account, as before")
    }

    // MARK: - Helpers

    private static func message(id: String, device: String = "") -> ChatMessage {
        var message = ChatMessage(
            id: id,
            from: "7574fdec-ca31-44ac-9d43-0e6e870fe4d5",
            to: "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167",
            ephemeralPublicKey: Data(),
            messageNumber: 0,
            content: Data(),
            suiteId: 0,
            timestamp: 1_785_854_458
        )
        message.senderDeviceId = device
        return message
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
        tracker.markPending(.account(peer))

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
        tracker.markPending(.account(confirmed))
        tracker.markConfirmed(.account(confirmed))
        XCTAssertFalse(tracker.consumeLapse(confirmed), "the peer-ack path replays the hold itself")

        let lapsed = "watchdog-peer-\(UUID().uuidString)"
        tracker.markPending(.account(lapsed))
        tracker.releaseLapsed(lapsed)
        XCTAssertFalse(tracker.consumeLapse(lapsed), "the watchdog give-up path replays it itself")
    }

    /// A lapse recorded by the TTL, then superseded by an explicit confirm, must not survive: the
    /// confirm's own replay already drained the buffer.
    @MainActor
    func testConfirmAfterLapseDoesNotLeaveADoubleReplay() {
        let tracker = SessionConfirmationTracker.shared
        let peer = "raced-peer-\(UUID().uuidString)"
        tracker.markPending(.account(peer))
        tracker.expireForTesting(peer)
        _ = tracker.isPending(peer)          // records the lapse
        tracker.markConfirmed(.account(peer)) // peer ack lands late and replays
        XCTAssertFalse(tracker.consumeLapse(peer), "one release, one replay")
    }

    // MARK: - A confirmation is about one ratchet

    private func device(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 16)
    }

    /// Two devices of one account, two SRIs, one `session_ready`. The ratchet that answered is
    /// confirmed; the one that did not still holds the gate, because sending now would put user
    /// content on a ratchet nobody has acknowledged — which is the whole job of the gate.
    ///
    /// Mutation: key the tracker by account again — the first confirmation releases both and this
    /// reddens.
    @MainActor
    func testOneDeviceConfirmingDoesNotReleaseItsSibling() {
        let tracker = SessionConfirmationTracker.shared
        let account = "acct-\(UUID().uuidString)"
        let first = device(0xa1), second = device(0xb2)

        tracker.markPending(PeerAddress(account: account, device: first))
        tracker.markPending(PeerAddress(account: account, device: second))
        tracker.markConfirmed(PeerAddress(account: account, device: first))

        XCTAssertTrue(tracker.isPending(account), "the sibling's ratchet is still unconfirmed")

        tracker.markConfirmed(PeerAddress(account: account, device: second))
        XCTAssertFalse(tracker.isPending(account), "both ratchets confirmed — nothing left to hold")
    }

    /// A `session_ready` that names no device — unsealed, or a client older than the sender
    /// certificate — settles the account. A gate nothing can release is a conversation that stops
    /// sending for the length of the window, which is worse than the coarse answer.
    @MainActor
    func testANamelessConfirmationSettlesTheWholeAccount() {
        let tracker = SessionConfirmationTracker.shared
        let account = "acct-\(UUID().uuidString)"
        tracker.markPending(PeerAddress(account: account, device: device(0xc3)))
        tracker.markPending(PeerAddress(account: account, device: device(0xd4)))

        tracker.markConfirmed(.account(account))

        XCTAssertFalse(tracker.isPending(account))
    }

    /// The gate goes up before the init can say which devices it opened, so it is raised on the
    /// account and the init's answer replaces it. The placeholder must not outlive that answer:
    /// confirming the opened ratchet would otherwise leave an account-keyed entry holding sends
    /// for the rest of the window.
    ///
    /// Mutation: drop `dropPlaceholder` from `markPending` — this reddens.
    @MainActor
    func testTheAccountPlaceholderIsReplacedByTheDevicesTheInitOpened() {
        let tracker = SessionConfirmationTracker.shared
        let account = "acct-\(UUID().uuidString)"
        let opened = device(0xe5)

        tracker.markPending(.account(account))          // raised before the init answers
        tracker.markPending(PeerAddress(account: account, device: opened))
        tracker.markConfirmed(PeerAddress(account: account, device: opened))

        XCTAssertFalse(tracker.isPending(account), "nothing but the replaced placeholder was left")
    }

    /// One watchdog serves the conversation, so its tick reads the ratchet that has waited
    /// longest. Reading the youngest would keep a long-held gate up past its window.
    @MainActor
    func testTheWatchdogReadsTheOldestUnconfirmedRatchet() {
        let tracker = SessionConfirmationTracker.shared
        let account = "acct-\(UUID().uuidString)"
        let old = device(0xf6), young = device(0x17)

        tracker.markPending(PeerAddress(account: account, device: old))
        tracker.expireForTesting(account)                       // backdates what exists so far
        tracker.markPending(PeerAddress(account: account, device: young))

        XCTAssertEqual(tracker.watchdogTick(account), .giveUp, "the oldest decides")
    }

    // MARK: - Not covered here, on purpose
    //
    // That a held message is never `markProcessed`'d — the property that turned this delay into a
    // permanent loss — is asserted by construction (`holdUntilConfirmResolves` has no ACK call)
    // and not by a test: reaching it means standing up MessageRouter with CryptoManager, Core Data
    // and three singletons, and a test that cannot fail against a mutation is worse than none
    // (decisions/ios-semantic-divergence-signals, amendment 2026-08-04). The device-log check is
    // `grep confirm_hold` with no matching `Skipping already-processed` for the same id.

    // MARK: - The replay must know which session it was held against (build 579 regression)

    private static let heldAgainst = SessionEpoch(rawValue: "e51d7a03bc9426f8107d3e5ab84c92f6")!
    private static let replacement = SessionEpoch(rawValue: "77b93c1ae02f56d4b8319ca7e0d452f1")!

    /// The defect, stated: a peer init held while session A was live, replayed after session B
    /// replaced it, cannot decrypt — and the failure drove `heal` → `manual_reset`, deleting the
    /// healthy B. Three times in one hour on 2026-08-05.
    func testPeerInitHeldAgainstAnOlderSessionIsSuperseded() {
        XCTAssertEqual(
            SessionReducer.heldReplayDisposition(
                heldAgainst: Self.heldAgainst,
                current: Self.replacement,
                kind: .handshake
            ),
            .superseded
        )
    }

    /// Held against the same session that is still current: nothing replaced it, so it replays.
    func testPeerInitHeldAgainstTheCurrentSessionReplays() {
        XCTAssertEqual(
            SessionReducer.heldReplayDisposition(
                heldAgainst: Self.heldAgainst,
                current: Self.heldAgainst,
                kind: .handshake
            ),
            .replay
        )
    }

    /// No session now — this init may be the very handshake that establishes one. Dropping it
    /// here would be the discard that §1d forbids.
    func testPeerInitWithNoCurrentSessionAlwaysReplays() {
        XCTAssertEqual(
            SessionReducer.heldReplayDisposition(
                heldAgainst: Self.heldAgainst,
                current: nil,
                kind: .handshake
            ),
            .replay
        )
    }

    /// Held while we had no session at all, and one exists now: it was established after this init
    /// was set aside, so the handshake this init belongs to has already concluded.
    func testPeerInitHeldWithNoSessionIsSupersededOnceOneExists() {
        XCTAssertEqual(
            SessionReducer.heldReplayDisposition(
                heldAgainst: nil,
                current: Self.replacement,
                kind: .handshake
            ),
            .superseded
        )
    }

    /// A payload is never dropped on age. Losing user content on a guess is the failure the hold
    /// exists to prevent; an undecryptable payload is the healing path's question, not this one's.
    func testPayloadAlwaysReplaysHoweverStale() {
        XCTAssertEqual(
            SessionReducer.heldReplayDisposition(
                heldAgainst: Self.heldAgainst,
                current: Self.replacement,
                kind: .midRatchet
            ),
            .replay
        )
    }

    /// The comparison is equality, not ordering. Under `establishedAt` the predicate asked whether
    /// the current session was *newer* than the held one, which quietly replayed anything that read
    /// as older — including a replacement whose stamp landed in the same second. Two different
    /// epochs are two different sessions, in either direction.
    func testAnyDifferentEpochIsSuperseded() {
        XCTAssertEqual(
            SessionReducer.heldReplayDisposition(
                heldAgainst: Self.replacement,
                current: Self.heldAgainst,
                kind: .handshake
            ),
            .superseded,
            "there is no 'older' epoch to make an exception for"
        )
    }
}
