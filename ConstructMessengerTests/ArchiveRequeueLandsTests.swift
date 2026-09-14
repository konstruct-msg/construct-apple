//
//  ArchiveRequeueLandsTests.swift
//  ConstructMessengerTests
//
//  `DeliveryStatusAuthorityTests` asserts what a session archive should *decide* about an
//  outgoing message, and every one of those assertions was correct while the decision had no
//  effect at all: `afterSessionArchive` returned `.resend`, the caller assigned `.queued`, and the
//  guarded setter refused it, because `.queued` ranks below the `.sent` that every ordinary
//  message holds by the time a session is archived.
//
//  So the reducer was tested and the write was not. These tests are the missing half: they assert
//  the stored status, not the returned verdict.
//
//  Three-simulator run 2026-08-26 — a message composed into a concurrent-init race. A could not
//  decrypt it and logged "29faa550… awaits the peer's re-send"; the peer had already had its own
//  re-queue refused, so the re-send A was waiting for could never be scheduled. The sender's row
//  kept a checkmark, the recipient never saw the message, and nothing retried.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class ArchiveRequeueLandsTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    private func message(status: DeliveryStatus, retryCount: Int16 = 0) -> Message {
        let msg = Message(context: context)
        msg.id = UUID().uuidString
        msg.fromUserId = "me"
        msg.toUserId = "peer"
        msg.contentType = .regular
        msg.timestamp = Date()
        msg.isSentByMe = true
        msg.deliveryStatus = status
        msg.retryCount = retryCount
        return msg
    }

    // MARK: - The write the guard used to refuse

    /// The defect, at the smallest scale that shows it: the archive decides `.resend` for a
    /// `.sent` message, and the stored status must actually become `.queued`.
    ///
    /// Mutation: assign through `deliveryStatus` instead of `applyArchiveOutcome` — the setter
    /// refuses the demotion and this reddens.
    func testASentMessageIsActuallyRequeued() {
        let msg = message(status: .sent)
        XCTAssertTrue(msg.applyArchiveOutcome(.resend), "the write must report that it landed")
        XCTAssertEqual(msg.deliveryStatus, .queued,
                       "the ciphertext on the server is the one the peer just lost the keys for")
    }

    /// The same for the terminal verdict: a message that exhausted its retries must show as failed,
    /// not keep a checkmark that stands for nothing.
    ///
    /// Mutation: assign through `deliveryStatus` — reddens for the same reason.
    func testAnExhaustedMessageIsActuallyFailed() {
        let msg = message(status: .sent, retryCount: 99)
        XCTAssertTrue(msg.applyArchiveOutcome(.giveUp))
        XCTAssertEqual(msg.deliveryStatus, .failed)
    }

    /// The guard exists for a reason and this writer must not undo it: a receipt from the peer is
    /// end-to-end evidence, and no session change unsays it. `.keep` is the branch that protects
    /// it, so the bypass can never reach a delivered row.
    ///
    /// Mutation: have `.keep` fall through to `.queued`, or drop the `.keep` case in the caller —
    /// this reddens.
    func testADeliveredMessageIsNeverRetracted() {
        let msg = message(status: .delivered)
        XCTAssertFalse(msg.applyArchiveOutcome(.keep))
        XCTAssertEqual(msg.deliveryStatus, .delivered)

        // And the decision that guards it, over the same row.
        XCTAssertEqual(
            DeliveryStatusTransition.afterSessionArchive(
                status: msg.deliveryStatus, retryCount: 0, maxRetries: 3),
            .keep
        )
    }

    /// A second archive for a row already re-queued changes nothing and must say so, or the
    /// caller's counter reports a re-queue per END_SESSION in a storm rather than per message.
    ///
    /// Mutation: return `true` unconditionally — this reddens.
    func testRequeuingAnAlreadyQueuedRowReportsNoChange() {
        let msg = message(status: .queued)
        XCTAssertFalse(msg.applyArchiveOutcome(.resend))
        XCTAssertEqual(msg.deliveryStatus, .queued)
    }

    // MARK: - Decision and write, over the same row

    /// The pairing that was missing. Each status a real outgoing message can hold when its session
    /// is archived, run through the decision and then through the write, with the stored value
    /// asserted at the end.
    ///
    /// Mutation: any that makes the write refuse a demotion — every `.sent` row reddens here.
    func testEveryOutgoingStatusReachesTheStatusItsVerdictNames() {
        let expected: [(DeliveryStatus, Int16, DeliveryStatus)] = [
            (.sending,   0,  .queued),
            (.queued,    0,  .queued),
            (.sent,      0,  .queued),
            (.failed,    0,  .queued),
            (.sent,     99,  .failed),
            (.delivered, 0,  .delivered),
            (.delivered, 99, .delivered),
        ]
        for (start, retries, want) in expected {
            let msg = message(status: start, retryCount: retries)
            let outcome = DeliveryStatusTransition.afterSessionArchive(
                status: msg.deliveryStatus, retryCount: Int(retries), maxRetries: 3)
            msg.applyArchiveOutcome(outcome)
            XCTAssertEqual(msg.deliveryStatus, want,
                           "\(start) with \(retries) retries decided \(outcome) but stored \(msg.deliveryStatus)")
        }
    }

    /// Everything that is *not* an archive still goes through the guard. Fixing the archive path
    /// must not open the demotion to the writers the guard was built to stop — the build-585
    /// incident in `DeliveryStatusAuthorityTests` is a transport failure demoting a delivered row.
    ///
    /// Mutation: relax `DeliveryStatusTransition.resolve` to allow any transition — this reddens.
    func testAnOrdinaryWriterStillCannotDemote() {
        let msg = message(status: .sent)
        msg.deliveryStatus = .queued
        XCTAssertEqual(msg.deliveryStatus, .sent, "a plain assignment must still be refused")

        let delivered = message(status: .delivered)
        delivered.deliveryStatus = .failed
        XCTAssertEqual(delivered.deliveryStatus, .delivered)
    }
}
