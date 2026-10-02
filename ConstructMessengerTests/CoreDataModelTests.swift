//
//  CoreDataModelTests.swift
//  ConstructMessengerTests
//
//  `Chat.messages` named `Chat` as its inverse's entity from model 9 to 11, so it had no inverse
//  at all: adding a message to a chat's set left `message.chat` unset, and momc warned on every
//  build. A model version already on devices cannot be edited — the entity hash changes and the
//  store stops opening — so the fix is version 12, and old versions keep the warning.
//

import CoreData
import XCTest
@testable import Construct_Messenger

final class CoreDataModelTests: XCTestCase {

    private var modelBundle: URL {
        get throws { try XCTUnwrap(Bundle.main.url(forResource: "ConstructMessenger", withExtension: "momd")) }
    }

    private func model(_ version: String) throws -> NSManagedObjectModel {
        let url = try modelBundle.appendingPathComponent("\(version).mom")
        return try XCTUnwrap(NSManagedObjectModel(contentsOf: url), version)
    }

    /// Every relationship of the current model has an inverse that names it back.
    func testEveryRelationshipIsReciprocal() {
        let current = PersistenceController(inMemory: true).container.managedObjectModel
        for entity in current.entities {
            for (name, relationship) in entity.relationshipsByName {
                let inverse = relationship.inverseRelationship
                XCTAssertNotNil(inverse, "\(entity.name ?? "").\(name) has no inverse")
                XCTAssertEqual(inverse?.inverseRelationship, relationship, "\(entity.name ?? "").\(name)")
            }
        }
    }

    /// Model 14 adds the profile version to `User` (`profileEditedAtMs` with a default,
    /// `pendingAvatarRef`, `pendingAvatarSince` optional): a store written by 13 opens under it
    /// without a mapping model.
    func testVersion13MigratesLightweight() throws {
        let current = PersistenceController(inMemory: true).container.managedObjectModel
        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(forSourceModel: model("ConstructMessenger 13"), destinationModel: current)
        )
    }

    /// Model 13 adds `ServerMessageId` and nothing else: a store written by 12 opens under it
    /// without a mapping model.
    func testVersion12MigratesLightweight() throws {
        let current = PersistenceController(inMemory: true).container.managedObjectModel
        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(forSourceModel: model("ConstructMessenger 12"), destinationModel: current)
        )
    }

    /// A store written by version 11 opens under the current model without a mapping model.
    func testVersion11MigratesLightweight() throws {
        let current = PersistenceController(inMemory: true).container.managedObjectModel
        XCTAssertNoThrow(
            try NSMappingModel.inferredMappingModel(forSourceModel: model("ConstructMessenger 11"), destinationModel: current)
        )
    }
}
