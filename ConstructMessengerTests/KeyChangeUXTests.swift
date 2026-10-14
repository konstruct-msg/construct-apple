//
//  KeyChangeUXTests.swift
//  ConstructMessengerTests
//
//  Thread 5.4: acknowledging clears the warning.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class KeyChangeUXTests: XCTestCase {

    private var container: NSPersistentContainer!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
    }

    override func tearDown() {
        KeyChangeUX.setActiveChatContact(nil)
        LocalRepositories.useContactsForTesting(nil)
        container = nil
        super.tearDown()
    }

    private func makeUser(id: String, kt: KTStatus, key: Data?) {
        let ctx = container.viewContext
        let user = User(context: ctx)
        user.id = id
        user.username = "alice"
        user.displayName = "Alice"
        user.isContact = true
        user.isBlocked = false
        user.isSharingWithMe = false
        user.amISharingWith = false
        user.addedAt = Date()
        user.ktStatus = kt
        user.knownIdentityKey = key
        try! ctx.save()
    }

    func testAcknowledgeClearsFailed() {
        let id = "14f28d31-1234-4abc-8def-aaaaaaaaaaaa"
        let key = Data(repeating: 0xAB, count: 32)
        makeUser(id: id, kt: .failed, key: key)

        let ok = KeyChangeUX.acknowledgeKeyChange(userId: id)
        XCTAssertTrue(ok)

        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", id)
        container.viewContext.refreshAllObjects()
        let user = try! container.viewContext.fetch(fetch).first!
        XCTAssertEqual(user.ktStatus, .verified)
        XCTAssertEqual(user.knownIdentityKey, key)
    }

    func testAcknowledgeNoOpWhenUnverified() {
        let id = "14f28d31-1234-4abc-8def-bbbbbbbbbbbb"
        makeUser(id: id, kt: .unverified, key: nil)
        XCTAssertFalse(KeyChangeUX.acknowledgeKeyChange(userId: id))
    }

    func testGlobalNoticeSuppressedWhenChatActive() {
        let id = "14f28d31-1234-4abc-8def-dddddddddddd"
        KeyChangeUX.setActiveChatContact(id)
        // Should not crash / not clear active contact
        makeUser(id: id, kt: .verified, key: nil)
        XCTAssertTrue(KeyChangeUX.raise(.addressChanged, userId: id))
        XCTAssertEqual(KeyChangeUX.activeChatContactId, id)
    }
}
