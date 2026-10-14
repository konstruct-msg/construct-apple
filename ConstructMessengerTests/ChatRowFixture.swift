//
//  ChatRowFixture.swift
//  ConstructMessengerTests
//
//  The managed `Chat` a test links its `Message` fixtures to. The app names a chat by id since
//  2026-10-12 and has no such bridge; tests still build transcripts row by row in Core Data.
//

import CoreData
import XCTest
@testable import Construct_Messenger

extension Chat {
    /// The row `id` in `context`, as last saved — refreshed, so a write through `ChatStore` on
    /// another context shows.
    static func row(_ id: String, in context: NSManagedObjectContext) throws -> Chat {
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        req.shouldRefreshRefetchedObjects = true
        return try XCTUnwrap(context.fetch(req).first, "no Chat row \(id)")
    }
}
