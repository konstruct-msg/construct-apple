//
//  ContactLinkDeletedFlagTests.swift
//  ConstructMessengerTests
//
//  2026-10-05: two devices deleted each other and re-added by invite. The inviter created the
//  contact on `invite_accepted` but left the peer in `DeletedContactsStore`, so every
//  mid-ratchet message from the peer was dropped as "from deleted contact" while the peer's
//  screen read *sent*. Only a handshake clears that flag, and the peer — the responder — never
//  sends one.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class ContactLinkDeletedFlagTests: XCTestCase {

    private let peer = "14f28d31-0000-0000-0000-0000000000bb"
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
        DeletedContactsStore.shared.remove(peer)
    }

    override func tearDown() {
        DeletedContactsStore.shared.remove(peer)
        context = nil
        super.tearDown()
    }

    func testMakingAPrunedPeerAContactStopsShieldingThem() throws {
        DeletedContactsStore.shared.add(peer)
        XCTAssertTrue(DeletedContactsStore.shared.isDeleted(peer), "precondition: the prune shields")

        try ContactLinkService.shared.createOrUpdateContact(
            userId: peer, username: nil, displayName: nil, context: context
        )

        XCTAssertFalse(
            DeletedContactsStore.shared.isDeleted(peer),
            "a contact the user just added must not be dropped as deleted"
        )
    }

    func testAnUnrelatedPrunedPeerStaysShielded() throws {
        let other = "14f28d31-0000-0000-0000-0000000000cc"
        DeletedContactsStore.shared.add(other)
        defer { DeletedContactsStore.shared.remove(other) }

        try ContactLinkService.shared.createOrUpdateContact(
            userId: peer, username: nil, displayName: nil, context: context
        )

        XCTAssertTrue(DeletedContactsStore.shared.isDeleted(other))
    }
}
