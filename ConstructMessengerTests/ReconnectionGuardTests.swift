//
//  ReconnectionGuardTests.swift
//  ConstructMessengerTests
//
//  Tests for the deduplication and guard stores that prevent the stale-OTPK
//  redelivery cascade discovered in production (April 2026).
//
//  These tests are pure Swift — no Rust, no CoreData, no network.
//  They guard the receipt semantics contract. The FailedInitMessageStore tests went with the store
//  (todo/252): a session renews by sending, so no exception re-processes a first message.
//

import XCTest
@testable import Construct_Messenger

final class ReconnectionGuardTests: XCTestCase {

    // MARK: - 7. Receipt status contract

    /// Guard against proto enum renumbering or accidental alias.
    /// .delivered must advance the server cursor; .failed must be distinct.
    func testReceiptStatus_DeliveredAndFailed_AreDistinct() {
        let delivered = Shared_Proto_Signaling_V1_ReceiptStatus.delivered
        let failed    = Shared_Proto_Signaling_V1_ReceiptStatus.failed

        XCTAssertNotEqual(delivered, failed,
            ".delivered and .failed must be distinct proto values — mixing them causes the stale-OTPK redelivery loop")
    }

    func testReceiptStatus_UnrecognizedIsNotDelivered() {
        let unrecognized = Shared_Proto_Signaling_V1_ReceiptStatus.UNRECOGNIZED(0)
        let delivered    = Shared_Proto_Signaling_V1_ReceiptStatus.delivered
        XCTAssertNotEqual(unrecognized, delivered)
    }
}
