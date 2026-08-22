//
//  RelayedReceiptCompatTests.swift
//  ConstructMessengerTests
//
//  On 2026-08-02 the client stopped *sending* the plaintext stream receipt: `DirectReceipt`
//  carried `recipient_user_id` — the original sender — in the clear, and on a sealed envelope the
//  server sets `sender_id` to empty on purpose, so our receipt was the server's only source for
//  the sender↔recipient link sealed sender exists to withhold.
//
//  Receiving one still parses. The stream entry carries a cursor that has to advance, and one
//  arriving at all is worth seeing — nothing has sent these since 2026-08-02, so it means either a
//  peer three weeks stale or something that is not a peer.
//
//  **What it no longer does is turn the checkmark on** (2026-08-22). The branch was originally kept
//  on the grounds that "reading a receipt leaks nothing", which is true and is about privacy. The
//  property that argument did not weigh is authenticity: gRPC/TLS ends at the server, so a plaintext
//  receipt on that stream is a value the server chose to send, and `.delivered` is the one thing the
//  UI says about the *other person*. The refusal lives in
//  `DeliveryStatusTransition.marksDelivered`.
//
//  These tests also pin why `.failed` was dropped rather than kept: the parser discards it, and
//  `relay_delivery_receipt` never re-queues, so a `.failed` receipt was inert on both ends while
//  still carrying the identity in the clear.
//
//  Acceptance is mutation-based: delete the `.receipt` case body in `MessageStreamParser.parse`
//  (return nil) and testRelayedDeliveredReceipt_IsStillParsed must go red.
//

import XCTest
import SwiftProtobuf
@testable import Construct_Messenger

final class RelayedReceiptCompatTests: XCTestCase {

    private func response(
        status: Shared_Proto_Signaling_V1_ReceiptStatus,
        messageIds: [String],
        cursor: String? = nil
    ) -> Shared_Proto_Services_V1_MessageStreamResponse {
        var direct = Shared_Proto_Signaling_V1_DirectReceipt()
        direct.messageIds = messageIds
        direct.status = status
        direct.timestamp = 1_785_662_600

        var receipt = Shared_Proto_Signaling_V1_DeliveryReceipt()
        receipt.direct = direct

        var response = Shared_Proto_Services_V1_MessageStreamResponse()
        response.receipt = receipt
        if let cursor { response.streamCursor = cursor }
        return response
    }

    /// The entry still parses, because its cursor still has to advance and because a relayed
    /// receipt arriving is a fact worth logging. What it does *not* do is decided one layer up.
    func testRelayedDeliveredReceipt_IsStillParsed() {
        let event = MessageStreamParser.parse(
            response(status: .delivered, messageIds: ["msg-a", "msg-b"], cursor: "1776522670299-0")
        )

        guard case .deliveryReceipt(let ids, let cursor)? = event else {
            return XCTFail("Relayed delivered receipt must still parse — older peers depend on it")
        }
        XCTAssertEqual(ids, ["msg-a", "msg-b"])
        XCTAssertEqual(cursor, "1776522670299-0")
    }

    /// `.failed` is inert end to end — the reason it was not worth keeping as a send.
    func testFailedReceipt_IsIgnored() {
        XCTAssertNil(
            MessageStreamParser.parse(response(status: .failed, messageIds: ["msg-a"])),
            ".failed never reached the sender's UI; sending it only leaked the identity"
        )
    }

    /// An empty id list confirms nothing, so it must not be mistaken for a confirmation.
    func testEmptyReceipt_IsIgnored() {
        XCTAssertNil(MessageStreamParser.parse(response(status: .delivered, messageIds: [])))
    }

    // MARK: - Which source may turn the checkmark on

    /// The defect, stated as the property it breaks. Anything that can write to the message stream
    /// could turn on a checkmark claiming end-to-end delivery for a message that was never
    /// delivered — and the thing that can write to it is the server, which is the party sealed
    /// sender exists to withhold from.
    ///
    /// Mutation: return `true` for `.relayedStream`.
    func testARelayedReceiptCannotMarkAMessageDelivered() {
        XCTAssertFalse(
            DeliveryStatusTransition.marksDelivered(.relayedStream),
            "a plaintext receipt on the stream is a value the server chose to send"
        )
    }

    /// And the one that can. Losing this is losing every checkmark in the app, which is the failure
    /// the refusal above must not turn into.
    ///
    /// Mutation: return `false` for `.peerE2E`.
    func testThePeersOwnReceiptStillMarksItDelivered() {
        XCTAssertTrue(DeliveryStatusTransition.marksDelivered(.peerE2E))
    }

    /// `.delivered` outranks everything and nothing demotes it — which is right, and is exactly why
    /// the set of things allowed to produce it has to be narrow. Stated together so the two rules
    /// are read as one: the rank makes the claim permanent, the source decides who may make it.
    func testDeliveredIsUnDemotableWhichIsWhyTheSourceMatters() {
        XCTAssertNil(
            DeliveryStatusTransition.resolve(current: .delivered, proposed: .failed),
            "once delivered, no later writer takes it back"
        )
    }
}
