//
//  LocalDataWipeTests.swift
//  ConstructMessengerTests
//
//  Signing out, deleting the account and being removed from another device leave nothing of the
//  account here. `decisions/sign-out-wipes-the-device.md`
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class LocalDataWipeTests: XCTestCase {

    // MARK: - What survives

    /// Only the speech models and the log directory are kept. Mutation: keep anything else by
    /// name — a store of the account's would outlive the wipe.
    func testOnlyTheNamedExceptionsSurvive() {
        XCTAssertTrue(LocalDataWipe.survives("whisper-models", in: .applicationSupport))
        XCTAssertTrue(LocalDataWipe.survives("Logs", in: .documents))

        for name in ["ConstructMessenger.sqlite", "ConstructMessenger.sqlite-wal", ".ConstructMessenger_SUPPORT",
                     "media", "ct_secure", "PendingReassembly"] {
            XCTAssertFalse(LocalDataWipe.survives(name, in: .applicationSupport), name)
        }
        for name in ["thumbnails", "stickers", "media", "veil-scores.sqlite"] {
            XCTAssertFalse(LocalDataWipe.survives(name, in: .caches), name)
        }
        XCTAssertFalse(LocalDataWipe.survives("konstruct-history-1.cthf", in: .temporary))
        XCTAssertFalse(LocalDataWipe.survives("whisper-models", in: .caches), "an exception is per root")
    }

    // MARK: - The store is replaced, not emptied row by row

    func testTheStoreComesBackEmptyAndUsable() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let user = User(context: context)
        user.id = "14f28d31-0000-0000-0000-00000000000b"
        user.username = ""
        user.displayName = "Bob"
        user.addedAt = Date()
        user.isContact = true
        user.isBlocked = false
        user.isSharingWithMe = false
        user.amISharingWith = false
        try context.save()

        var swept = false
        controller.replaceStoreWithEmpty { swept = true }

        XCTAssertTrue(swept)
        XCTAssertEqual(controller.container.persistentStoreCoordinator.persistentStores.count, 1)
        XCTAssertEqual(try context.count(for: User.fetchRequest()), 0)
    }

    // MARK: - Which rejection wipes

    /// The server's word for a deactivated device, and nothing else. "Device not found" is also
    /// what an unapproved join request gets — wiping on it would erase a device mid-link.
    func testOnlyAnInactiveDeviceIsARemovedOne() {
        XCTAssertTrue(AuthViewModel.isRemovedDevice(
            "RPCError(code: unauthenticated, message: \"Device is inactive\")"
        ))
        XCTAssertFalse(AuthViewModel.isRemovedDevice("RPCError(code: unauthenticated, message: \"Device not found\")"))
        XCTAssertFalse(AuthViewModel.isRemovedDevice("GRPCCore.RPCError error 16"))
        XCTAssertFalse(AuthViewModel.isRemovedDevice("deadline exceeded"))
    }

    // MARK: - Defaults

    func testTheAccountsStrayDefaultsAreWiped() {
        let defaults = UserDefaults(suiteName: "LocalDataWipeTests")!
        defer { defaults.removePersistentDomain(forName: "LocalDataWipeTests") }
        defaults.set(Data([1]), forKey: "message_thumbnail_abc_0")
        defaults.set(["m1"], forKey: "com.construct.failed_init_message_ids")

        AccountWipeKeys.wipe(defaults)

        XCTAssertNil(defaults.object(forKey: "message_thumbnail_abc_0"))
        XCTAssertNil(defaults.object(forKey: "com.construct.failed_init_message_ids"))
    }
}
