//
//  DeliveryReceiptPreferenceTests.swift
//  ConstructMessengerTests
//
//  Every receipt woke the sender's phone with a banner the server cannot tell from a message, and
//  told them when this phone was online. Security → "Delivery receipts" stops ours (2026-10-19).
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class DeliveryReceiptPreferenceTests: XCTestCase {

    private let ourAccount = "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"
    private let peerAccount = "7574fdec-2c1a-4a0f-9d3e-1b0b6f2c9a41"
    private var context: NSManagedObjectContext!
    private var saved: Any?

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
        SessionAddressing.ownAccountOverrideForTesting = ourAccount
        saved = UserDefaults.standard.object(forKey: DeliveryReceiptPreference.key)
        DeliveryReceiptBatcher.shared.discardForTesting()
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: DeliveryReceiptPreference.key)
        SessionAddressing.ownAccountOverrideForTesting = nil
        DeliveryReceiptBatcher.shared.discardForTesting()
        context = nil
        super.tearDown()
    }

    /// Mutation: default `sends` to `false` — this reddens; an install that never opened the
    /// setting must keep sending, as every build before this one did.
    func testReceiptsAreOnUntilTurnedOff() {
        UserDefaults.standard.removeObject(forKey: DeliveryReceiptPreference.key)
        XCTAssertTrue(DeliveryReceiptPreference.sends)
        UserDefaults.standard.set(false, forKey: DeliveryReceiptPreference.key)
        XCTAssertFalse(DeliveryReceiptPreference.sends)
    }

    /// Mutation: drop the `DeliveryReceiptPreference.sends` check in `sendDeliveryReceipt` — this
    /// reddens on the second half; the first half proves the same call still enqueues when on.
    func testTurnedOffNothingIsEnqueued() async {
        let batcher = DeliveryReceiptBatcher.shared

        UserDefaults.standard.set(true, forKey: DeliveryReceiptPreference.key)
        OutboundSessionService.sendDeliveryReceipt(
            for: ["6f1e3c2a-0000-4000-8000-000000000011"], to: peerAccount, in: context
        )
        await settle { batcher.pendingCountForTesting == 1 }
        XCTAssertEqual(batcher.pendingCountForTesting, 1, "on: the receipt is owed and enqueued")

        batcher.discardForTesting()
        UserDefaults.standard.set(false, forKey: DeliveryReceiptPreference.key)
        OutboundSessionService.sendDeliveryReceipt(
            for: ["6f1e3c2a-0000-4000-8000-000000000012"], to: peerAccount, in: context
        )
        await settle { batcher.pendingCountForTesting > 0 }
        XCTAssertEqual(batcher.pendingCountForTesting, 0, "off: nothing leaves for the sender")
    }

    /// `sendDeliveryReceipt` hops to the main actor to enqueue. Yield until the condition holds or
    /// the budget runs out; the assertion, not this, decides the outcome.
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<50 {
            if done() { return }
            await Task.yield()
        }
    }
}
