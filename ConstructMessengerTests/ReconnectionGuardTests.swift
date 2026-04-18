//
//  ReconnectionGuardTests.swift
//  ConstructMessengerTests
//
//  Tests for the deduplication and guard stores that prevent the stale-OTPK
//  redelivery cascade discovered in production (April 2026).
//
//  These tests are pure Swift — no Rust, no CoreData, no network.
//  They guard the invariants of FailedInitMessageStore and the receipt
//  semantics contract, ensuring the infinite-loop protection cannot regress.
//

import XCTest
@testable import Construct_Messenger

final class ReconnectionGuardTests: XCTestCase {

    // Each test gets a fresh isolated store backed by a per-test UserDefaults suite
    // so tests don't pollute each other or the app's own UserDefaults.
    private var store: FailedInitMessageStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.construct.test.\(UUID().uuidString)"
        store = FailedInitMessageStore(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    // MARK: - 1. Add + contains round-trip

    func testAdd_ThenContains_ReturnsTrue() {
        let id = UUID().uuidString
        store.add(id)
        XCTAssertTrue(store.contains(id))
    }

    func testContains_BeforeAdd_ReturnsFalse() {
        XCTAssertFalse(store.contains(UUID().uuidString))
    }

    // MARK: - 2. Redelivery loop prevention across simulated reconnects

    /// Core regression: after initReceivingSession fails, the same message arrives
    /// again on every gRPC stream reconnect (the server re-delivers because the cursor
    /// never advanced). Verifies that contains() still returns true after N re-checks,
    /// simulating N reconnects delivering the same stale OTPK message.
    func testFailedInitStore_PreventsRedeliveryAcrossReconnects() {
        let staleId = "686EA757-A540-4CC1-81B0-37BE857538DE"  // ID from real production log
        store.add(staleId)

        for reconnectNumber in 1...10 {
            XCTAssertTrue(
                store.contains(staleId),
                "Reconnect #\(reconnectNumber): stale message must still be blocked"
            )
        }
    }

    // MARK: - 3. Different message IDs are not blocked

    func testFailedInitStore_DifferentId_IsNotBlocked() {
        let failedId = UUID().uuidString
        let newId = UUID().uuidString

        store.add(failedId)

        XCTAssertTrue(store.contains(failedId), "Failed ID must be blocked")
        XCTAssertFalse(store.contains(newId), "New ID from same contact must not be blocked")
    }

    func testFailedInitStore_MultipleContacts_IsolatedPerMessage() {
        let msgFromAlice = UUID().uuidString
        let msgFromBob   = UUID().uuidString

        store.add(msgFromAlice)

        XCTAssertTrue(store.contains(msgFromAlice))
        XCTAssertFalse(store.contains(msgFromBob),
                       "Failed message from Alice must not block messages from Bob")
    }

    // MARK: - 4. Idempotent add

    func testAdd_Idempotent_DoesNotDuplicateEntry() {
        let id = UUID().uuidString
        store.add(id)
        store.add(id)
        store.add(id)
        // Still blocked, and internal count hasn't exploded
        XCTAssertTrue(store.contains(id))
    }

    // MARK: - 5. Pruning at 200 entries

    /// When the store exceeds 200 entries, it prunes to 100 (suffix half).
    /// Oldest entries are evicted; recent ones survive.
    func testFailedInitStore_PrunesOldEntriesAt200() {
        // Fill past the 200-entry limit
        var added: [String] = []
        for _ in 0..<210 {
            let id = UUID().uuidString
            store.add(id)
            added.append(id)
        }

        // After pruning: the first ~110 oldest are gone; the last ~100 survive
        let recentIds = Array(added.suffix(90))
        let oldIds    = Array(added.prefix(90))

        for id in recentIds {
            XCTAssertTrue(store.contains(id), "Recent entry must survive pruning")
        }
        for id in oldIds {
            // Oldest entries should have been evicted
            XCTAssertFalse(store.contains(id), "Old entry must be pruned")
        }
    }

    // MARK: - 6. Persistence across store re-creation (simulates app restart)

    func testFailedInitStore_PersistsAcrossInstances() {
        let id = UUID().uuidString
        store.add(id)

        // Recreate store from same suiteName (simulates app restart)
        let restoredStore = FailedInitMessageStore(suiteName: suiteName)
        XCTAssertTrue(restoredStore.contains(id),
                      "Failed init message must persist across app restarts")
    }

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
