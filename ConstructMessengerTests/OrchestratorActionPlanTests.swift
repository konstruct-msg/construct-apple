//
//  OrchestratorActionPlanTests.swift
//  ConstructMessengerTests
//
//  The composition nothing covered: an orchestrator action list carrying MORE than one
//  instruction.
//
//  Every message in the field logs of 2026-08-01 returned exactly one action — nine of ten. The
//  tenth was an X3DH carrier arriving on an existing session, where the core emits
//  `applyPqContribution` *and* `checkAckInDb`. `MessageRouter` gated the ACK round-trip on
//  `actions.count == 1`, so that one message was ACKed as delivered without ever being
//  decrypted, and the sender's next message diverged the ratchet into an END_SESSION cycle.
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

    /// The exact list from the field log: an X3DH carrier whose ACK cache missed after a
    /// restart. Both instructions must be recovered — recovering only one is the bug.
    func testCarrierWithAckMiss_RecoversBothInstructions() {
        let kem = Data(repeating: 0xAB, count: 1088)
        let plan = OrchestratorActionPlan(actions: [
            .applyPqContribution(contactId: peer, kemSs: kem),
            .checkAckInDb(messageId: messageId)
        ])

        XCTAssertEqual(plan.ackCheckMessageId, messageId,
                       "checkAckInDb must be found even when it is not the only action — "
                       + "missing it strands the message undecrypted (the 2026-08-01 defect)")
        XCTAssertEqual(plan.kemCiphertext, kem,
                       "the KEM ciphertext must survive for decapsulation")
    }

    /// Order is the core's business, not ours. The same pair reversed must read identically.
    func testInstructionOrderIsIrrelevant() {
        let kem = Data(repeating: 0x07, count: 1088)
        let forward = OrchestratorActionPlan(actions: [
            .applyPqContribution(contactId: peer, kemSs: kem),
            .checkAckInDb(messageId: messageId)
        ])
        let reversed = OrchestratorActionPlan(actions: [
            .checkAckInDb(messageId: messageId),
            .applyPqContribution(contactId: peer, kemSs: kem)
        ])

        XCTAssertEqual(forward.ackCheckMessageId, reversed.ackCheckMessageId)
        XCTAssertEqual(forward.kemCiphertext, reversed.kemCiphertext)
    }

    /// A decrypted carrier: the PQ contribution rides alongside the routing verdict and the
    /// storage actions, and must not be lost among them.
    func testCarrierAmongRoutingAndStorageActions_StillYieldsContribution() {
        let kem = Data(repeating: 0x5A, count: 1088)
        let plan = OrchestratorActionPlan(actions: [
            .applyPqContribution(contactId: peer, kemSs: kem),
            .messageDecrypted(contactId: peer, messageId: messageId, plaintext: Data("hi".utf8)),
            .saveSessionToSecureStore(key: peer, data: Data(repeating: 1, count: 430)),
            .persistAck(messageId: messageId, timestamp: 1_785_615_000)
        ])

        XCTAssertEqual(plan.kemCiphertext, kem)
        XCTAssertNil(plan.ackCheckMessageId, "no ACK question was asked in this list")
    }

    // MARK: - The pre-existing single-action shapes must keep working

    /// The shape the old `count == 1` guard handled, and the only one it handled.
    func testLoneAckCheck_StillRecovered() {
        let plan = OrchestratorActionPlan(actions: [.checkAckInDb(messageId: messageId)])

        XCTAssertEqual(plan.ackCheckMessageId, messageId)
        XCTAssertNil(plan.kemCiphertext)
    }

    /// An ordinary message on an established session: no carrier, no ACK question.
    func testPlainDecrypt_YieldsNeitherInstruction() {
        let plan = OrchestratorActionPlan(actions: [
            .messageDecrypted(contactId: peer, messageId: messageId, plaintext: Data("hi".utf8))
        ])

        XCTAssertNil(plan.kemCiphertext)
        XCTAssertNil(plan.ackCheckMessageId)
    }

    func testEmptyActions_YieldNeitherInstruction() {
        let plan = OrchestratorActionPlan(actions: [])

        XCTAssertNil(plan.kemCiphertext)
        XCTAssertNil(plan.ackCheckMessageId)
    }

    /// A duplicate the core dropped still carries the contribution instruction, because the core
    /// pushes it before routing. The router must NOT apply it — that decision belongs to the
    /// caller (it applies only on `.messageDecrypted`), but the plan still reports it faithfully
    /// rather than second-guessing the core.
    func testDroppedDuplicate_ReportsContributionForCallerToJudge() {
        let kem = Data(repeating: 0xC3, count: 1088)
        let plan = OrchestratorActionPlan(actions: [
            .applyPqContribution(contactId: peer, kemSs: kem)
        ])

        XCTAssertEqual(plan.kemCiphertext, kem)
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
