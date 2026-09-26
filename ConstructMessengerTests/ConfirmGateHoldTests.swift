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
        // No fold at all since 2026-09-26: the replay that needed one is the core's.
        XCTAssertFalse(
            source.contains("awaitsAcknowledgementFromAnyDevice("),
            "the decision and the release are per device and live in the core"
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
    // permanent loss — is asserted by construction (the `.heldPendingAck` branch has no ACK call)
    // and not by a test: reaching it means standing up MessageRouter with CryptoManager, Core Data
    // and three singletons, and a test that cannot fail against a mutation is worse than none
    // (decisions/ios-semantic-divergence-signals, amendment 2026-08-04). The device-log check is
    // `grep confirm_hold` with no matching `Skipping already-processed` for the same id.

    // MARK: - The hold is the core's; this side keeps the envelope and does what it is told
    //
    // Which messages are held, against which epoch, and which of them are superseded moved to
    // `construct-core` 2026-09-26 (`Orchestrator::release_confirm_holds`, tested there with the
    // build-579 and 2026-08-21 cases). What is left to get wrong here is not carrying out the
    // release, so that is what these check.

    private func source(_ path: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The release can ride on any event's answer, and several router branches never hand their
    /// answer to the executor — so it is carried out where every answer passes.
    ///
    /// Mutation: drop `dispatchHeldReleases(actions)` from `handleOrchestratorEvent` — this reddens.
    func testEveryAnswerOfTheCoreCarriesItsReleasesOut() {
        let crypto = source("ConstructMessenger/Security/CryptoManager.swift")
        guard let handle = crypto.range(of: "func handleOrchestratorEvent(") else {
            return XCTFail("the one entry to the core is gone — if it moved, this moves with it")
        }
        XCTAssertTrue(
            crypto[handle.lowerBound...].prefix(1_200).contains("dispatchHeldReleases(actions)"),
            "a release dropped with an answer is a message held until its envelope expires"
        )
        XCTAssertTrue(
            source("ConstructMessenger/Services/Session/SessionCoordinator.swift")
                .contains("CryptoManager.shared.onHeldReleased = "),
            "and something must be listening"
        )
    }

    /// The router keeps no replay rule and no buffer of its own beside the core's.
    ///
    /// Mutation: bring back `replayHeldMessages` or the per-message epoch stamp — this reddens.
    func testTheRouterKeepsNoHoldBufferOfItsOwn() {
        let router = source("ConstructMessenger/Services/Messaging/MessageRouter.swift")
        XCTAssertFalse(router.isEmpty)
        for carrier in ["func replayHeldMessages", "var heldAgainst", "heldReplayDisposition("] {
            XCTAssertFalse(router.contains(carrier), "\(carrier) is a second hold beside the core's")
        }
        XCTAssertTrue(router.contains("case .replayHeld"), "the release has a reader")
        XCTAssertTrue(router.contains("case .heldSuperseded"), "and so does the drop")
    }
}
