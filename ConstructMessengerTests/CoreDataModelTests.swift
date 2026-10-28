//
//  CoreDataModelTests.swift
//  ConstructMessengerTests
//
//  `Chat.messages` named `Chat` as its inverse's entity from model 9 to 11, so it had no inverse
//  at all: adding a message to a chat's set left `message.chat` unset, and momc warned on every
//  build. A model version already on devices cannot be edited — the entity hash changes and the
//  store stops opening — so the fix was version 12.
//
//  Versions 1–14 were removed on 2026-10-28, when every install was on 15 (since build 695,
//  2026-10-04). What could still carry an older store is a `.ctbackup` file or a Nearby
//  transfer; staging refuses those (`LocalBackupService.stageTransferPayload`), because applied,
//  such a store fails to open and the store's recovery deletes it.
//

import CoreData
import XCTest
@testable import Construct_Messenger

final class CoreDataModelTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDataModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
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

    /// Writes an SQLite store of `model` with no WAL, so the file alone is the store.
    private func writeStore(of model: NSManagedObjectModel, named name: String) throws -> URL {
        let url = scratch.appendingPathComponent("\(name).sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]
        )
        try coordinator.remove(store)
        return url
    }

    /// A schema the bundle does not carry — what a pre-15 backup is to this build.
    private var foreignModel: NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "Chat"
        let attribute = NSAttributeDescription()
        attribute.name = "legacyOnly"
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = true
        entity.properties = [attribute]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    func testCanOpenStore_CurrentModel() throws {
        let current = PersistenceController(inMemory: true).container.managedObjectModel
        XCTAssertTrue(PersistenceController.canOpenStore(at: try writeStore(of: current, named: "current")))
    }

    func testCanOpenStore_ModelTheBundleDoesNotCarry() throws {
        XCTAssertFalse(PersistenceController.canOpenStore(at: try writeStore(of: foreignModel, named: "foreign")))
    }

    func testCanOpenStore_NotAStore() throws {
        let url = scratch.appendingPathComponent("garbage.sqlite")
        try Data("not a database".utf8).write(to: url)
        XCTAssertFalse(PersistenceController.canOpenStore(at: url))
    }

    /// Staging a backup whose store this build cannot open throws, and leaves no restore pending:
    /// otherwise the next launch would replace the device's store with it and then delete both.
    @MainActor
    func testStagingRefusesStoreOfUnknownVersion() throws {
        let defaults = UserDefaults.standard
        let key = LocalBackupService.pendingRestoreKey
        XCTAssertFalse(defaults.bool(forKey: key), "a restore is already pending in the test host")

        let store = try Data(contentsOf: try writeStore(of: foreignModel, named: "backup"))
        let manifest = try JSONSerialization.data(withJSONObject: [
            "version": 1, "createdAt": 0, "coreSQLiteSize": store.count, "keyStoreSQLiteSize": 1,
        ])
        var payload = Data()
        for blob in [manifest, store, Data(), Data([0])] {
            var length = UInt64(blob.count).littleEndian
            payload.append(Data(bytes: &length, count: 8))
            payload.append(blob)
        }

        XCTAssertThrowsError(try LocalBackupService.shared.stageTransferPayload(payload)) {
            guard case BackupError.unsupportedVersion = $0 else {
                return XCTFail("expected unsupportedVersion, got \($0)")
            }
        }
        XCTAssertFalse(defaults.bool(forKey: key))
        let staging = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ct_restore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
}
