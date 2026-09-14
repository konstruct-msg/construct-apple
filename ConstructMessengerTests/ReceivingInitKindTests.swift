//
//  ReceivingInitKindTests.swift
//  ConstructMessengerTests
//
//  `messageNumber == 0` is not "this is an X3DH handshake". After a DH ratchet the new
//  sending chain starts at N=0, and feeding that leftover to `initReceivingSession`
//  fails with "PQ epoch N secret unavailable (current epoch 0)" then clears the pending
//  queue — including any real handshake sitting behind it.
//
//  Device logs 2026-08-19, both sides, six times:
//      msgNum: 0 sealedBox: 283B oneTimePrekeyId: 0 kemCiphertext: 0B
//      → All 1 prekey(s) failed … PQ epoch 2 secret unavailable (current epoch 0)
//  The ephemeral `95ac454b` was a live sending-chain key, not an X3DH ephemeral.
//

import XCTest
@testable import Construct_Messenger

final class ReceivingInitKindTests: XCTestCase {

    private func kind(
        msgNum: UInt32 = 0,
        otpk: UInt32 = 0,
        kem: Int = 0,
        epoch: UInt32 = 0,
        sri: Bool = false
    ) -> SessionReducer.ReceivingInitKind {
        SessionReducer.receivingInitKind(
            messageNumber: msgNum,
            oneTimePreKeyId: otpk,
            kemCiphertextBytes: kem,
            pqMessageEpoch: epoch,
            isSessionResetInit: sri
        )
    }

    /// The field failure: PQ-tagged, no OTPK, no KEM, N=0.
    func testPqEpochLeftover_IsNotAHandshake() {
        XCTAssertEqual(
            kind(epoch: 2),
            .midSessionLeftover,
            "a PQ epoch on a message with no handshake fields is a live sending-chain leftover"
        )
    }

    func testMidRatchet_IsNotAHandshake() {
        XCTAssertEqual(kind(msgNum: 3, epoch: 2), .midRatchet)
        XCTAssertEqual(kind(msgNum: 1), .midRatchet)
    }

    func testOtpkMakesItAHandshakeEvenWithEpoch() {
        XCTAssertEqual(kind(otpk: 1_000_282, kem: 1088, epoch: 0), .handshake)
        XCTAssertEqual(kind(otpk: 1_000_274), .handshake)
    }

    func testKemMakesItAHandshake() {
        XCTAssertEqual(kind(kem: 1088), .handshake)
    }

    func testSessionResetInitIsAlwaysAHandshake() {
        XCTAssertEqual(kind(sri: true), .handshake)
        XCTAssertEqual(kind(epoch: 2, sri: true), .handshake)
    }

    /// 3-DH classic (no OTPK, no KEM, epoch 0) is the reproducible fallback after
    /// `otpkUnreproducible`. Classifying it as a leftover would refuse the one init
    /// that still works when OTPKs are gone.
    func testClassicThreeDH_StaysAHandshake() {
        XCTAssertEqual(kind(), .handshake)
    }

}

/// Э3: the drained queue splits on a **named** opener, not on a position.
///
/// Both drain sites passed `skippingFirst: true` and skipped `queued.first`, which was the message
/// the session actually opened on only by coincidence. The heal path opens on whatever
/// `SessionHealingService` recorded; the first-message path, since it began trying every eligible
/// carrier, opens on whichever carrier the peer's device really sent — for a multi-device peer,
/// routinely not the first one queued.
final class DrainSplitTests: XCTestCase {

    /// **The defect, stated as a test.** The session opened on the second queued carrier. The
    /// first must still be routed, and it is the *second* whose watermark is released. The
    /// implementation this replaces did the exact opposite of both.
    func testTheOpenerIsRemovedByIdNotByPosition() {
        let split = SessionReducer.drainSplit(
            queuedIds: ["a", "b", "c"],
            openedOn: "b"
        )
        XCTAssertEqual(split.resolve, "b")
        XCTAssertEqual(split.toRoute, ["a", "c"])
    }

    /// The common single-device case, where the opener genuinely is first. This must keep working
    /// unchanged — the fix must cost nothing to a peer with one device.
    func testAFirstPositionOpenerStillWorks() {
        let split = SessionReducer.drainSplit(queuedIds: ["a", "b"], openedOn: "a")
        XCTAssertEqual(split.resolve, "a")
        XCTAssertEqual(split.toRoute, ["b"])
    }

    /// An opener that is not in the queue is normal, not a loss: the first-message path opens on
    /// the message that triggered the fetch, which reaches init before it is enqueued. Everything
    /// queued still gets routed, and nothing is resolved — resolving an id we never held would
    /// release a watermark belonging to no queue entry.
    func testAnOpenerThatWasNeverQueuedResolvesNothingAndDropsNothing() {
        let split = SessionReducer.drainSplit(queuedIds: ["a", "b"], openedOn: "trigger")
        XCTAssertNil(split.resolve)
        XCTAssertEqual(split.toRoute, ["a", "b"])
    }

    /// No opener at all — the heal-less drain. Everything queued is routed.
    func testNoOpenerRoutesEverything() {
        let split = SessionReducer.drainSplit(queuedIds: ["a", "b"], openedOn: nil)
        XCTAssertNil(split.resolve)
        XCTAssertEqual(split.toRoute, ["a", "b"])
    }

    /// Order is preserved. The queue is FIFO and the messages behind a handshake are the rest of
    /// that device's chain; routing them out of order would ask the ratchet for skipped keys it
    /// has no reason to hold.
    func testOrderSurvivesTheSplit() {
        let split = SessionReducer.drainSplit(
            queuedIds: ["m1", "m2", "m3", "m4"],
            openedOn: "m3"
        )
        XCTAssertEqual(split.toRoute, ["m1", "m2", "m4"])
    }

    /// Exactly one entry is removed even if the same id appears twice. The queue dedups on
    /// enqueue, so a repeat means something upstream is wrong — dropping both would turn that into
    /// a lost message, which is the more expensive of the two mistakes.
    func testADuplicateIdLosesOnlyOneEntry() {
        let split = SessionReducer.drainSplit(queuedIds: ["a", "b", "a"], openedOn: "a")
        XCTAssertEqual(split.toRoute, ["b", "a"])
    }

    /// An empty queue is an empty answer, not a crash. This is the state after a give-up cleared
    /// the queue while init was still in flight.
    func testAnEmptyQueueSplitsToNothing() {
        let split = SessionReducer.drainSplit(queuedIds: [], openedOn: "a")
        XCTAssertNil(split.resolve)
        XCTAssertTrue(split.toRoute.isEmpty)
    }
}
