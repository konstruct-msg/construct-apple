//
//  RelayedReceiptCompatTests.swift
//  ConstructMessengerTests
//
//  On 2026-08-02 the client stopped *sending* the plaintext stream receipt: `DirectReceipt`
//  carried `recipient_user_id` — the original sender — in the clear, and on a sealed envelope the
//  server sets `sender_id` to empty on purpose, so our receipt was the server's only source for
//  the sender↔recipient link sealed sender exists to withhold.
//
//  Receiving one still has to work. A peer on an older build keeps sending them, and the server
//  relays through `MessageEnvelope::from_receipt`; if that inbound branch is later pruned as dead
//  code — it is unreachable from our own sends now — those peers silently lose every checkmark.
//  Reading a receipt leaks nothing, so the branch stays.
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

    /// The compatibility path we deliberately kept: a peer still sending stream receipts must
    /// still be able to turn our checkmark on.
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
}
