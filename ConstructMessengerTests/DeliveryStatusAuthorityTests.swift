//
//  DeliveryStatusAuthorityTests.swift
//  ConstructMessengerTests
//
//  Build 585, device 0a1c609f — a message the peer had already confirmed was demoted back
//  into the retry queue by the failure path of its own send:
//
//      10:55:0x  Receipt: message 0224077a… marked delivered (was sending)
//      10:55:47  SendMessage gRPC error: code=unavailable, message=Stream unexpectedly closed.
//      10:55:47  Transport failure — queueing 4deb2192… for safe retry
//      10:55:47  Updated message status to queued for 4deb2192…
//      10:55:47  Transport failure — queueing 0224077a… for safe retry
//      10:55:47  Updated message status to queued for 0224077a…   ← was delivered
//
//  The request had arrived; it was the reply that died. Three sends were demoted this way in one
//  second, and an earlier session left the residue behind:
//
//      sendQueuedMessages: no queued messages with reusable wire payload or recoverable
//      plaintext for 0a1c609f… — preserving local queue           (lines 825, 1892, 2908)
//
//  Both endings are wrong: with the plaintext still around the message is sent a second time,
//  and without it the row sticks at "queued" forever.
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class DeliveryStatusAuthorityTests: XCTestCase {

    // MARK: - The incident

    func testDeliveredIsNotDemotedByLateTransportFailure() {
        XCTAssertNil(
            DeliveryStatusTransition.resolve(current: .delivered, proposed: .queued),
            "0224077a…: the peer's receipt outranks the send RPC's own broken reply path"
        )
    }

    func testDeliveredIsNotDemotedToFailed() {
        XCTAssertNil(DeliveryStatusTransition.resolve(current: .delivered, proposed: .failed))
    }

    func testDeliveredIsNotDemotedBySlowerServerAck() {
        // Same race, one rung down: the peer answered before our own server response landed.
        XCTAssertNil(
            DeliveryStatusTransition.resolve(current: .delivered, proposed: .sent),
            "the server saying 'accepted' is weaker news than the peer saying 'received'"
        )
    }

    func testSentIsNotDemotedByTransportFailure() {
        XCTAssertNil(
            DeliveryStatusTransition.resolve(current: .sent, proposed: .queued),
            "the server already has it — re-queuing sends it twice"
        )
    }

    func testSentIsNotDemotedToFailedOrRestarted() {
        XCTAssertNil(DeliveryStatusTransition.resolve(current: .sent, proposed: .failed))
        XCTAssertNil(DeliveryStatusTransition.resolve(current: .sent, proposed: .sending))
    }

    // MARK: - What must NOT be blocked
    //
    // A rule that refuses writes is one misfire away from freezing every status in the app.
    // These are the transitions the product depends on.

    func testPeerReceiptStillCorrectsAFalseFailure() {
        // StreamLifecycleCoordinator's "Receipt: corrected false-failed message … → .delivered".
        XCTAssertEqual(DeliveryStatusTransition.resolve(current: .failed, proposed: .delivered), .delivered)
    }

    func testPeerReceiptStillPromotesFromEveryAttemptStatus() {
        for current in [DeliveryStatus.sending, .queued, .failed, .sent] {
            XCTAssertEqual(
                DeliveryStatusTransition.resolve(current: current, proposed: .delivered), .delivered,
                "\(current) → delivered must always be allowed"
            )
        }
    }

    func testNormalSendPathIsUntouched() {
        XCTAssertEqual(DeliveryStatusTransition.resolve(current: .sending, proposed: .sent), .sent)
        XCTAssertEqual(DeliveryStatusTransition.resolve(current: .sending, proposed: .queued), .queued)
        XCTAssertEqual(DeliveryStatusTransition.resolve(current: .sending, proposed: .failed), .failed)
    }

    func testRetryCanRestartAQueuedOrFailedMessage() {
        XCTAssertEqual(DeliveryStatusTransition.resolve(current: .queued, proposed: .sending), .sending)
        XCTAssertEqual(DeliveryStatusTransition.resolve(current: .failed, proposed: .sending), .sending)
    }

    func testStrandedQueuedRowCanBeMarkedFailed() {
        // MessageRetryManager marks rows failed once nothing can ever send them.
        XCTAssertEqual(DeliveryStatusTransition.resolve(current: .queued, proposed: .failed), .failed)
    }

    func testIdempotentWriteIsAllowed() {
        for status in [DeliveryStatus.sending, .sent, .delivered, .queued, .failed] {
            XCTAssertEqual(DeliveryStatusTransition.resolve(current: status, proposed: status), status)
        }
    }

    // MARK: - The rule is in the setter, so the setter is what gets asserted
    //
    // ~30 call sites assign `deliveryStatus` directly. Testing only the pure function would prove
    // the rule correct and prove nothing about it being reached.

    @MainActor
    func testCoreDataRowRefusesTheDemotionThatShipped() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let message = Message(context: context)
        message.id = "0224077a-41a9-4cdc-9640-821b5d8c3699"
        message.isSentByMe = true

        message.deliveryStatus = .sending
        message.deliveryStatus = .delivered      // peer receipt
        message.deliveryStatus = .queued         // transport failure, 40 seconds later

        XCTAssertEqual(message.deliveryStatus, .delivered)
    }

    @MainActor
    func testCoreDataRowStillAcceptsALegitimateRetryCycle() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let message = Message(context: context)
        message.id = UUID().uuidString
        message.isSentByMe = true

        message.deliveryStatus = .sending
        message.deliveryStatus = .queued
        XCTAssertEqual(message.deliveryStatus, .queued)

        message.deliveryStatus = .sending
        XCTAssertEqual(message.deliveryStatus, .sending)

        message.deliveryStatus = .sent
        XCTAssertEqual(message.deliveryStatus, .sent)

        message.deliveryStatus = .delivered
        XCTAssertEqual(message.deliveryStatus, .delivered)
    }
}
