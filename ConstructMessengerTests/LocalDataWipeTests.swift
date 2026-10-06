//
//  LocalDataWipeTests.swift
//  ConstructMessengerTests
//
//  Signing out, deleting the account and being removed from another device leave nothing of the
//  account here. `decisions/sign-out-wipes-the-device.md`
//

import CoreData
import XCTest
import GRPCCore
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

    /// The server's number for a deactivated device, and nothing else. `.notFound` is also what an
    /// unapproved join request gets — wiping on it would erase a device mid-link. Mutation: compare
    /// with `!= .unspecified` — the join request wipes.
    func testOnlyARemovedDeviceIsARemovedOne() {
        XCTAssertTrue(AuthViewModel.isRemovedDevice(.removed, overDirectTLS: true))
        XCTAssertFalse(AuthViewModel.isRemovedDevice(.notFound, overDirectTLS: true))
        XCTAssertFalse(AuthViewModel.isRemovedDevice(.unspecified, overDirectTLS: true))
    }

    /// Through VEIL the relay sees plaintext gRPC and can forge the answer. Mutation: drop the
    /// path check — any relay can erase the device.
    func testARelayedAnswerNeverWipes() {
        XCTAssertFalse(AuthViewModel.isRemovedDevice(.removed, overDirectTLS: false))
    }

    // MARK: - Reading the refusal

    private func refusal(_ code: RPCError.Code, _ message: String, trailer: String?) -> Shared_Proto_Services_V1_DeviceRefusal {
        var metadata = Metadata()
        if let trailer { metadata.addString(trailer, forKey: DeviceRefusalReading.metadataKey) }
        return DeviceRefusalReading.refusal(of: RPCError(code: code, message: message, metadata: metadata))
    }

    /// The number decides. Mutation: read the key from a different name — every refusal reads
    /// as unspecified and a removed device keeps its data forever.
    func testTheRefusalIsReadFromItsNumber() {
        XCTAssertEqual(refusal(.unauthenticated, "Device is inactive", trailer: "1"), .removed)
        XCTAssertEqual(refusal(.unauthenticated, "Device not found", trailer: "2"), .notFound)
    }

    /// The text alone is not a reason: a server older than the number, or anything that only
    /// words its answer the same way. Mutation: fall back to matching the message.
    func testTheTextAloneIsNoReason() {
        XCTAssertEqual(refusal(.unauthenticated, "Device is inactive", trailer: nil), .unspecified)
        XCTAssertEqual(refusal(.unauthenticated, "Device is inactive", trailer: "removed"), .unspecified)
    }

    /// Only an UNAUTHENTICATED status refuses a device. Mutation: drop the code check.
    func testOnlyAnUnauthenticatedStatusCarriesARefusal() {
        XCTAssertEqual(refusal(.permissionDenied, "Device is inactive", trailer: "1"), .unspecified)
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
