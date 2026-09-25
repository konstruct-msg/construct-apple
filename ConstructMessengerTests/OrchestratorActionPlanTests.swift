//
//  OrchestratorActionPlanTests.swift
//  ConstructMessengerTests
//
//  The composition nothing covered: an orchestrator action list carrying MORE than one
//  instruction.
//
//  Every message in the field logs of 2026-08-01 returned exactly one action — nine of ten. The
//  tenth was an X3DH carrier arriving on an existing session, where the core emitted
//  `applyPqContribution` *and* `checkAckInDb`. `MessageRouter` gated the ACK round-trip on
//  `actions.count == 1`, so that one message was ACKed as delivered without ever being
//  decrypted, and the sender's next message diverged the ratchet into an END_SESSION cycle.
//  (`applyPqContribution` is gone since PQXDH v2; the core decapsulates itself. The lists below
//  pair the ACK question with actions that still exist — the hazard is the pairing, not which.)
//
//  Acceptance is mutation-based: reintroduce any length or position assumption in
//  OrchestratorActionPlan and this file must go red.
//

import XCTest
@testable import Construct_Messenger

final class OrchestratorActionPlanTests: XCTestCase {

    private let peer = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"
    private let messageId = "88c0835f-98a6-498a-a3d0-732c149eb242"

    // MARK: - The regression

    /// An ACK-cache miss that is not the only action. The question must be found — missing it
    /// strands the message undecrypted (the 2026-08-01 defect).
    func testAckMissAmongOtherActions_IsRecovered() {
        let plan = OrchestratorActionPlan(actions: [
            .scheduleTimer(timerId: "cooldown_expired:\(peer)", delayMs: 5068),
            .checkAckInDb(messageId: messageId)
        ])

        XCTAssertEqual(plan.ackCheckMessageId, messageId,
                       "checkAckInDb must be found even when it is not the only action")
    }

    /// Order is the core's business, not ours. The same pair reversed must read identically.
    func testInstructionOrderIsIrrelevant() {
        let forward = OrchestratorActionPlan(actions: [
            .scheduleTimer(timerId: "cooldown_expired:\(peer)", delayMs: 5068),
            .checkAckInDb(messageId: messageId)
        ])
        let reversed = OrchestratorActionPlan(actions: [
            .checkAckInDb(messageId: messageId),
            .scheduleTimer(timerId: "cooldown_expired:\(peer)", delayMs: 5068)
        ])

        XCTAssertEqual(forward.ackCheckMessageId, reversed.ackCheckMessageId)
    }

    // MARK: - The pre-existing single-action shapes must keep working

    /// The shape the old `count == 1` guard handled, and the only one it handled.
    func testLoneAckCheck_StillRecovered() {
        let plan = OrchestratorActionPlan(actions: [.checkAckInDb(messageId: messageId)])

        XCTAssertEqual(plan.ackCheckMessageId, messageId)
    }

    /// An ordinary message on an established session: no ACK question.
    func testPlainDecrypt_AsksNothing() {
        let plan = OrchestratorActionPlan(actions: [
            .messageDecrypted(contactId: peer, messageId: messageId, plaintext: Data("hi".utf8)),
            .saveToSecureStore(slot: .session(contactId: peer), data: Data(repeating: 1, count: 430)),
            .persistAck(messageId: messageId, timestamp: 1_785_615_000)
        ])

        XCTAssertNil(plan.ackCheckMessageId)
    }

    func testEmptyActions_AskNothing() {
        let plan = OrchestratorActionPlan(actions: [])

        XCTAssertNil(plan.ackCheckMessageId)
    }

    // MARK: - Routing verdict (healSuppressed is a decision, not "unknown")

    /// Device logs 2026-08-19: the core returned
    /// `[healSuppressed(..., retryAfterMs: 5068), scheduleTimer(cooldown_expired:…)]`
    /// and the router logged `unknown(healSuppressed),unknown(scheduleTimer)` then ERROR
    /// "no routing decision". That pair is a cooldown verdict. Treating it as `.none`
    /// skipped the timer and advanced the cursor past an un-ACKed message.
    func testHealSuppressedPlusTimer_IsAHealSuppressedVerdict() {
        let verdict = OrchestratorActionPlan.routingVerdict(from: [
            .healSuppressed(contactId: peer, retryAfterMs: 5068),
            .scheduleTimer(timerId: "cooldown_expired:\(peer)", delayMs: 5068)
        ])
        XCTAssertEqual(
            verdict,
            .healSuppressed(contactId: peer, retryAfterMs: 5068),
            "scheduleTimer is a chore riding alongside the verdict, not a missing decision"
        )
    }

    func testEndSessionSuppressedPlusTimer_IsAnEndSessionSuppressedVerdict() {
        let verdict = OrchestratorActionPlan.routingVerdict(from: [
            .endSessionSuppressed(contactId: peer, retryAfterMs: 5077),
            .scheduleTimer(timerId: "cooldown_expired:\(peer)", delayMs: 5077)
        ])
        XCTAssertEqual(
            verdict,
            .endSessionSuppressed(contactId: peer, retryAfterMs: 5077)
        )
    }

    func testTimerAlone_IsNotARoutingVerdict() {
        let verdict = OrchestratorActionPlan.routingVerdict(from: [
            .scheduleTimer(timerId: "cooldown_expired:\(peer)", delayMs: 100)
        ])
        XCTAssertEqual(verdict, .none, "a timer without a named decision is still nothing to route")
    }

    func testEmptyList_IsNone() {
        XCTAssertEqual(OrchestratorActionPlan.routingVerdict(from: []), .none)
    }

    /// Order is the core's. The first named verdict in the list wins, matching the
    /// scan MessageRouter used to do inline.
    func testFirstNamedVerdictWinsRegardlessOfChores() {
        let decrypted = OrchestratorActionPlan.routingVerdict(from: [
            .scheduleTimer(timerId: "x", delayMs: 1),
            .messageDecrypted(contactId: peer, messageId: messageId, plaintext: Data("hi".utf8)),
            .healSuppressed(contactId: peer, retryAfterMs: 1)
        ])
        XCTAssertEqual(decrypted, .decrypted)
    }
}
