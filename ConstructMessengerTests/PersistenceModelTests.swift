//
//  PersistenceModelTests.swift
//  ConstructMessengerTests
//
//  Every store in the process is built from one managed object model. Tests make many in-memory
//  stores, and until 2026-10-06 each loaded its own copy of the model; `User(context:)` finds its
//  entity by class across every model loaded, so with several copies it could take another
//  store's, and a save then failed with "references outside of their own stores" (Cocoa 133010)
//  or raised on a temporary object id — TODO 120, `HistorySnapshotEncoderTests`.
//

import CoreData
import XCTest
@testable import Construct_Messenger

final class PersistenceModelTests: XCTestCase {

    /// Mutation: load the model in `init` again — the two stores get different models.
    func testEveryStoreSharesOneModel() {
        let a = PersistenceController(inMemory: true).container
        let b = PersistenceController(inMemory: true).container
        XCTAssertTrue(a.managedObjectModel === b.managedObjectModel)
    }

    /// What the shared model is for: an object made by class in either store belongs to that
    /// store's model, and both save.
    func testAnObjectMadeByClassSavesInEitherStore() throws {
        let a = PersistenceController(inMemory: true).container.viewContext
        let b = PersistenceController(inMemory: true).container.viewContext
        for context in [a, b] {
            let user = User(context: context)
            user.id = UUID().uuidString
            user.username = "u"
            user.displayName = "U"
            XCTAssertTrue(user.entity.managedObjectModel === context.persistentStoreCoordinator?.managedObjectModel)
            let chat = Chat(context: context)
            chat.id = UUID().uuidString
            chat.otherUser = user
            XCTAssertNoThrow(try context.save())
        }
    }
}
