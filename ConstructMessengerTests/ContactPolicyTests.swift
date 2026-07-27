//
//  ContactPolicyTests.swift
//  ConstructMessengerTests
//
//  Thread 3: call permission = local isContact (and not blocked).
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class ContactPolicyTests: XCTestCase {

    private var container: NSPersistentContainer!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeUser(id: String, isContact: Bool, isBlocked: Bool = false) {
        let ctx = container.viewContext
        let user = User(context: ctx)
        user.id = id
        user.username = ""
        user.displayName = "Test"
        user.isContact = isContact
        user.isBlocked = isBlocked
        user.isSharingWithMe = false
        user.amISharingWith = false
        user.addedAt = Date()
        try! ctx.save()
    }

    func testCallableContactRequiresIsContact() {
        let ctx = container.viewContext
        let id = "14f28d31-1234-4abc-8def-0123456789ab"
        makeUser(id: id, isContact: false)
        XCTAssertFalse(ContactPolicy.isCallableContact(id, in: ctx))

        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", id)
        let user = try! ctx.fetch(fetch).first!
        user.isContact = true
        try! ctx.save()
        XCTAssertTrue(ContactPolicy.isCallableContact(id, in: ctx))
    }

    func testBlockedIsNotCallable() {
        let ctx = container.viewContext
        let id = "24f28d31-1234-4abc-8def-0123456789ab"
        makeUser(id: id, isContact: true, isBlocked: true)
        XCTAssertFalse(ContactPolicy.isCallableContact(id, in: ctx))
    }

    func testUnknownUserNotCallable() {
        let ctx = container.viewContext
        XCTAssertFalse(ContactPolicy.isCallableContact("34f28d31-1234-4abc-8def-0123456789ab", in: ctx))
    }

    func testEmptyIdNotCallable() {
        XCTAssertFalse(ContactPolicy.isCallableContact("", in: container.viewContext))
    }
}
