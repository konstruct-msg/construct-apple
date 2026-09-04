//
//  DeletedContactsRetentionTests.swift
//  ConstructMessengerTests
//
//  `DeletedContactsStore` shields a pruned contact from the server replaying their backlog
//  straight back into a fresh row. It is not a block — refusing someone is the block button's
//  job, and the server enforces that before delivery — and the entries expire, because a store
//  that never forgets is one.
//
//  2026-09-04: a contact was pruned at 16:18:15; the peer sent msgNum 1 through 5 over the next
//  fifty-one seconds, every one dropped by this store's verdict, every one reading *sent* on
//  their screen. The conversation came back only by re-scanning a QR code.
//

import XCTest
@testable import Construct_Messenger

final class DeletedContactsRetentionTests: XCTestCase {

    private let v2Key = "construct.deletedContacts.v2"
    private let v1Key = "com.konstruct.deletedContacts.v1"
    private let peer = "14f28d31-0000-0000-0000-0000000000aa"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: v2Key)
        UserDefaults.standard.removeObject(forKey: v1Key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: v2Key)
        UserDefaults.standard.removeObject(forKey: v1Key)
        super.tearDown()
    }



    // MARK: - The shield, and its end

    func testAFreshPruneIsShielded() {
        DeletedContactsStore.shared.add(peer)
        XCTAssertTrue(DeletedContactsStore.shared.isDeleted(peer))
        DeletedContactsStore.shared.remove(peer)
    }

    /// **The change.** Past the retention window no replay can still be carrying a handshake from
    /// before the prune, so the entry protects nothing and only withholds a person who may have
    /// written since. Before this, the entry was permanent and that was the whole defect.
    func testAnEntryOlderThanRetentionNoLongerShields() {
        let old = Date().addingTimeInterval(-DeletedContactsStore.retention - 60)
        XCTAssertFalse(
            DeletedContactsStore.isShielded(prunedAt: old, now: Date()),
            "a prune older than the server's message retention must stop shielding"
        )
    }

    /// The boundary is not accidentally inverted: just inside the window still shields.
    func testAnEntryInsideRetentionStillShields() {
        let recent = Date().addingTimeInterval(-DeletedContactsStore.retention + 60)
        XCTAssertTrue(DeletedContactsStore.isShielded(prunedAt: recent, now: Date()))
    }

    /// The window is the server's message retention, not an arbitrary number. Pinned so a change
    /// to it is a deliberate edit rather than a drift.
    func testRetentionIsSevenDays() {
        XCTAssertEqual(DeletedContactsStore.retention, 7 * 24 * 60 * 60)
    }

    // MARK: - Unmarking

    /// `MessageRouter` calls this when a handshake arrives and it decides to let the contact back.
    func testRemoveEndsTheShieldImmediately() {
        DeletedContactsStore.shared.add(peer)
        XCTAssertTrue(DeletedContactsStore.shared.isDeleted(peer))
        DeletedContactsStore.shared.remove(peer)
        XCTAssertFalse(DeletedContactsStore.shared.isDeleted(peer))
    }

    func testAContactNeverPrunedIsNotShielded() {
        XCTAssertFalse(DeletedContactsStore.shared.isDeleted("14f28d31-0000-0000-0000-0000000000ff"))
    }

    // MARK: - The key's name

    /// The rename is not cosmetic. `AccountWipeKeysTests` scans the sources for `"construct.…"`
    /// literals and fails on any that no wipe list claims; the old `com.konstruct.*` name sat
    /// outside that scan, so a store of contact ids survived an account wipe and the next
    /// identity on the device inherited the previous one's pruned contacts.
    func testTheStoreIsWipedWithTheAccount() {
        XCTAssertTrue(
            AccountWipeKeys.wiped.contains(v2Key),
            "\(v2Key) must be claimed by the wipe list, or a new identity inherits these ids"
        )
    }
}
