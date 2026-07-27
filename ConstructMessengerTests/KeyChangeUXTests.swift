//
//  KeyChangeUXTests.swift
//  ConstructMessengerTests
//
//  Thread 5.4: key-change acknowledge clears warning status.
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
    }

    override func tearDown() {
        KeyChangeUX.setActiveChatContact(nil)
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

    func testAcknowledgeClearsKeyChanged() {
        let id = "14f28d31-1234-4abc-8def-aaaaaaaaaaaa"
        let key = Data(repeating: 0xAB, count: 32)
        makeUser(id: id, kt: .keyChanged, key: key)

        let ok = KeyChangeUX.acknowledgeKeyChange(userId: id, context: container.viewContext)
        XCTAssertTrue(ok)

        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", id)
        let user = try! container.viewContext.fetch(fetch).first!
        XCTAssertEqual(user.ktStatus, .verified)
        XCTAssertEqual(user.knownIdentityKey, key)
    }

    func testAcknowledgeNoOpWhenUnverified() {
        let id = "14f28d31-1234-4abc-8def-bbbbbbbbbbbb"
        makeUser(id: id, kt: .unverified, key: nil)
        XCTAssertFalse(KeyChangeUX.acknowledgeKeyChange(userId: id, context: container.viewContext))
    }

    func testSafetyDeviceIdFromKnownKey() {
        let id = "14f28d31-1234-4abc-8def-cccccccccccc"
        // 32-byte identity key — deriveDeviceId is deterministic SHA256 prefix.
        let key = Data(repeating: 0x11, count: 32)
        makeUser(id: id, kt: .verified, key: key)
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", id)
        let user = try! container.viewContext.fetch(fetch).first!
        let deviceId = KeyChangeUX.safetyDeviceId(for: user)
        XCTAssertNotNil(deviceId)
        XCTAssertEqual(deviceId?.count, 32)
        XCTAssertEqual(deviceId, deriveDeviceId(identityPublicKey: [UInt8](key)))
    }

    func testGlobalNoticeSuppressedWhenChatActive() {
        let id = "14f28d31-1234-4abc-8def-dddddddddddd"
        KeyChangeUX.setActiveChatContact(id)
        // Should not crash / not clear active contact
        KeyChangeUX.notifyKeyChange(userId: id, displayName: "Alice")
        XCTAssertEqual(KeyChangeUX.activeChatContactId, id)
    }
}
