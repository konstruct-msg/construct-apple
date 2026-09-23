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

    // MARK: - The gate is not decided here any more

    // Three tests stood here until 2026-09-23, over `SessionReducer.confirmGateAction`: hold a
    // decrypt failure inside our own confirm window, never hold a control carrier, route
    // everything with the gate down. All three are `construct-core` now —
    // `a_teardown_is_held_while_our_own_announcement_is_unanswered`,
    // `a_heal_is_held_while_our_own_announcement_is_unanswered`,
    // `a_handshake_carrier_is_not_held_behind_the_wait_it_ends`,
    // `the_hold_ends_when_the_peer_acknowledges` — plus one this file could not have written,
    // `the_hold_is_asked_of_one_device_not_of_its_sibling`, because the predicate here took a
    // fold over the peer's device set as its input and so could not see the device at all.
    //
    // What is still asked here is everything the core cannot see: the classifier that tells an
    // acknowledgement from a handshake, and the buffer the hold writes into.

    /// The router must not grow a second gate. The one that stood here was asked at two call
    /// sites against a phase the core already kept, and the answer arrived as `.heldPendingAck`
    /// long before anyone noticed the question had an owner.
    ///
    /// Mutation: re-add a `confirmGateAction`-shaped branch around `.sendEndSession` — this
    /// reddens.
    func testTheRouterDecidesNoHoldOfItsOwn() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Messaging/MessageRouter.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("MessageRouter.swift must be readable from the test bundle")
        }
        // The call, not the word: the comments above both former call sites name what left.
        XCTAssertFalse(
            source.contains("SessionReducer.confirmGateAction("),
            "the hold is the core's decision and arrives as .heldPendingAck"
        )
        XCTAssertTrue(
            source.contains("case .heldPendingAck"),
            "a decision with no reader is a message the core buffered and the platform dropped"
        )
        // The one fold left is the *replay*, which is account-shaped because the buffer is: a
        // drain while any device's gate is still up would re-hold every message and read like a
        // flush. One use, and it is in `replayHeldMessages`.
        XCTAssertEqual(
            source.components(separatedBy: "awaitsAcknowledgementFromAnyDevice").count - 1, 1,
            "the fold belongs to the replay; the decision is per device and lives in the core"
        )
    }

    /// And the stamp a held message carries names the ratchet that refused it.
    ///
    /// It stamped `pinnedDevice(ofPeer:)` until 2026-09-23, because the gate was account-keyed
    /// and nothing here knew which ratchet had refused. For a peer whose pinned device is not the
    /// sender, that reads an epoch that never moves — so a superseded init replays into a heal
    /// that archives a healthy session, which is the 2026-08-05 build-579 cascade, and a live one
    /// can be dropped instead. An epoch is per ratchet, so both ends of the comparison are.
    ///
    /// Mutation: stamp `pinnedDevice(ofPeer: userId)` again — this reddens.
    func testTheHeldStampNamesTheRatchetThatRefusedIt() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Messaging/MessageRouter.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("MessageRouter.swift must be readable from the test bundle")
        }
        guard let hold = source.range(of: "private func holdUntilConfirmResolves") else {
            return XCTFail("the hold is gone — if it moved, this test moves with it")
        }
        let body = source[hold.lowerBound...].prefix(2_200)
        XCTAssertTrue(
            body.contains("sessionEpoch(for: heldAgainstDevice)"),
            "the core names the ratchet on .heldPendingAck; the stamp must be read from it"
        )
        XCTAssertFalse(
            body.contains("pinnedDevice(ofPeer:"),
            "the pinned device is the offline answer, not the one that refused this message"
        )
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

    // MARK: - The gate is the machine's, and this side only asks

    /// `SessionConfirmationTracker` was deleted 2026-09-23 (step 3 of
    /// `decisions/session-is-one-state-machine.md`). Seven tests stood here pinning its
    /// behaviour — the lazy-TTL lapse bookkeeping, the per-device confirmation, the nameless
    /// valve, the oldest-ratchet watchdog tick — and what they were really pinning is now
    /// `Opening { unacked_sri }` in `construct-core::session_machine`, tested there against a
    /// mock clock. The two that had no Rust equivalent went with the mechanism: the "unsettled
    /// lapse" set existed only because the gate could expire inside a *query*, from a call site
    /// with no context to replay with, and the machine's window does not do that — it ends on
    /// `OpeningGaveUp`, delivered to the one place that can act on it.
    ///
    /// What is left for this side to get wrong is asking the wrong thing, so that is what these
    /// check.
    private var coordinatorSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Session/SessionCoordinator.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The carriers, named — a reader who deletes the map and leaves the timer has left the next
    /// incident somewhere to grow back from.
    ///
    /// Mutation: re-add `private var tieBreakWatchdogs: [String: Task<Void, Never>] = [:]` —
    /// this reddens.
    @MainActor
    func testTheCoordinatorHoldsNoConfirmWindowOfItsOwn() {
        let source = coordinatorSource
        XCTAssertFalse(source.isEmpty, "SessionCoordinator.swift must be readable from the test bundle")
        for carrier in ["tieBreakWatchdogs", "tieBreakWatchdogRetryInterval", "confirmWindow"] {
            XCTAssertFalse(
                source.contains("var \(carrier)") || source.contains("let \(carrier)"),
                "\(carrier) is a second confirm window — the one that counts is the machine's"
            )
        }
    }

    /// And the release tells the machine rather than a map. If it stops, the window runs to its
    /// 75 s bound on every handshake and the only symptom is slow sends.
    ///
    /// Mutation: delete the `peerAcked` call from `releaseConfirmGate` — this reddens.
    @MainActor
    func testTheReleaseTellsTheMachine() {
        let source = coordinatorSource
        guard let release = source.range(of: "private func releaseConfirmGate") else {
            return XCTFail("the single confirm-gate release is gone — if it moved, this moves with it")
        }
        let body = source[release.lowerBound...].prefix(1_500)
        XCTAssertTrue(
            body.contains("peerAcked"),
            "an acknowledgement must reach the phase that is waiting for it"
        )
    }

    /// The account-shaped question is a fold over the device set, not a device the caller picked.
    /// One message becomes a copy per device, so one unanswered ratchet is enough to hold a send;
    /// asking about a single device would send on the siblings regardless.
    @MainActor
    func testTheAccountShapedQuestionIsAFold() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Security/CryptoManager.swift")
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertFalse(source.isEmpty, "CryptoManager.swift must be readable from the test bundle")
        guard let fold = source.range(of: "func awaitsAcknowledgementFromAnyDevice") else {
            return XCTFail("the fold is gone — the account-shaped answer has to come from somewhere")
        }
        let body = source[fold.lowerBound...].prefix(400)
        XCTAssertTrue(body.contains("deviceIds(ofPeer:"), "the set comes from the directory")
        XCTAssertTrue(body.contains("contains"), "and is folded, not indexed")
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
