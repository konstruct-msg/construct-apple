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

    private func refusal(_ code: RPCError.Code, _ message: String, trailer: String?) -> DeviceRefusalKind {
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

    // MARK: - A refresh refused as removed (todo 265)

    /// Counts what the coordinator would do to the held session; touches no Keychain.
    private actor SessionEnds {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// Runs one refresh that the server answers with `error`; returns how many times the held
    /// session was dropped. `directAfter` is the path when the answer came back.
    private func sessionEnds(
        refusedWith error: RPCError, directBefore: Bool = true, directAfter: Bool = true
    ) async -> Int {
        let ends = SessionEnds()
        let calls = DirectPathReadings([directBefore, directAfter])
        let coordinator = TokenRefreshCoordinator(
            performRefresh: { throw error },
            isDirectPath: { calls.next() },
            endHeldSession: { await ends.record() }
        )
        do {
            _ = try await coordinator.refreshIfPossible()
            XCTFail("a refused refresh must still throw to its caller")
        } catch {}
        return await ends.count
    }

    private func refused(_ trailer: String?, _ code: RPCError.Code = .unauthenticated) -> RPCError {
        var metadata = Metadata()
        if let trailer { metadata.addString(trailer, forKey: DeviceRefusalReading.metadataKey) }
        return RPCError(code: code, message: "Authentication failed: Device is inactive", metadata: metadata)
    }

    /// Device C removed while the app was closed comes back with an access token still inside its
    /// local lifetime. The refresh answer is the first place that says it is gone; unless the
    /// session goes there, every race guard sees a valid one and the wipe is never asked for.
    /// Mutation: drop `await endHeldSession()` — the removed device keeps its data.
    func testARefreshRefusedAsRemovedDropsTheHeldSession() async {
        let ends = await sessionEnds(refusedWith: refused("1"))
        XCTAssertEqual(ends, 1)
    }

    /// The table of refusals that are not "removed". "Already used" (no number) is the lost race
    /// the guard exists for; `.notFound` is a join request still waiting. Mutation: decide by
    /// `isRefreshTokenPermanentlyInvalid` instead of the number — the race drops a good session.
    func testOnlyRemovedDropsTheHeldSession() async {
        let none = await sessionEnds(refusedWith: refused(nil))
        let notFound = await sessionEnds(refusedWith: refused("2"))
        let denied = await sessionEnds(refusedWith: refused("1", .permissionDenied))
        XCTAssertEqual(none, 0, "a lost refresh race")
        XCTAssertEqual(notFound, 0, "a join request")
        XCTAssertEqual(denied, 0, "a refusal is UNAUTHENTICATED only")
    }

    /// Over VEIL the relay sees plaintext gRPC and could forge the number. Mutation: pass
    /// `overDirectTLS: true` — a relay drops the session; drop `&& isDirectPath()` — a path that
    /// moved to VEIL during the call counts as direct.
    func testARelayedRemovedAnswerKeepsTheHeldSession() async {
        let relayed = await sessionEnds(refusedWith: refused("1"), directBefore: false, directAfter: false)
        let movedMidCall = await sessionEnds(refusedWith: refused("1"), directBefore: true, directAfter: false)
        XCTAssertEqual(relayed, 0)
        XCTAssertEqual(movedMidCall, 0)
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

/// The path readings a refresh sees, before and after its call, in order.
private final class DirectPathReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [Bool]
    init(_ readings: [Bool]) { self.readings = readings }
    func next() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readings.isEmpty ? false : readings.removeFirst()
    }
}
