//
//  PruneForgetsDeviceSetTests.swift
//  ConstructMessengerTests
//
//  Deleting a contact has to resolve its devices before it destroys the rows that name them.
//

import XCTest
import CoreData
@testable import Construct_Messenger

/// `pruneContact` resolves the peer's device set, announces, deletes the local rows, then forgets
/// each device in the core. The order is the whole content of these tests: every step after the
/// delete asks a question the delete has already made unanswerable.
final class PruneForgetsDeviceSetTests: XCTestCase {

    private var context: NSManagedObjectContext!
    private let account = "14f28d31-2dab-44aa-a123-456789abcdef"
    private let identityKey = Data(repeating: 0x2b, count: 32)

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    @discardableResult
    private func makeUser(pinned: Bool) -> User {
        let user = User(context: context)
        user.id = account
        user.username = "wren"
        if pinned { user.knownIdentityKey = identityKey }
        try? context.save()
        return user
    }

    private func makePeerDevice(_ deviceId: String) {
        let row = PeerDevice(context: context)
        row.deviceId = deviceId
        row.accountId = account
        row.identityKey = identityKey
        row.firstSeenAt = Date()
        try? context.save()
    }

    /// The case the ordering exists for.
    ///
    /// A contact we have only ever received from has no `PeerDevice` row, so `deviceIds(ofPeer:)`
    /// falls back to `contactId(forPeer:)` — derived from `User.knownIdentityKey`, the row
    /// `pruneContactLocally` deletes. Resolve after the delete and the answer is empty, so every
    /// session with that contact survives the prune that was supposed to end it.
    ///
    /// The pin is driven through `pinnedIdentityKeyOverrideForTesting` rather than the context
    /// above, because `SessionAddressing.pinnedIdentityKey` does not read the context it is handed
    /// — it opens its own on `PersistenceController.shared`. That asymmetry is worth knowing about
    /// (a `deviceIds(ofPeer:in:)` whose fallback ignores `in:` is a seam that will mislead someone)
    /// but it is not what this test is about, so the override stands in for the row's presence.
    func testLosingThePinLosesTheOnlyNameItsDevicesHad() {
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { [identityKey] in
            $0 == self.account ? identityKey : nil
        }
        let before = SessionAddressing.deviceIds(ofPeer: account, in: context)
        XCTAssertEqual(before.count, 1, "a pinned key names exactly one device")

        // What `context.delete(user)` costs the resolver: the pin is gone with the row.
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = { _ in nil }
        defer { SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil }

        XCTAssertTrue(
            SessionAddressing.deviceIds(ofPeer: account, in: context).isEmpty,
            "this is why the device set is resolved before pruneContactLocally, not after"
        )
    }

    /// `PeerDevice` has no relationship to `User`, so those rows outlive the delete. That is what
    /// makes the failure above intermittent rather than total — and intermittent is worse, because
    /// a multi-device contact pruned correctly says nothing about a single-device one.
    func testPeerDeviceRowsSurviveTheUserDelete() {
        let user = makeUser(pinned: false)
        makePeerDevice("6f5e37ac9b1d4e2f8a0c5b7d3e1f9a2c")
        makePeerDevice("a1b2c3d4e5f60718293a4b5c6d7e8f90")

        XCTAssertEqual(SessionAddressing.deviceIds(ofPeer: account, in: context).count, 2)

        context.delete(user)
        try? context.save()

        XCTAssertEqual(
            Set(SessionAddressing.deviceIds(ofPeer: account, in: context)),
            ["6f5e37ac9b1d4e2f8a0c5b7d3e1f9a2c", "a1b2c3d4e5f60718293a4b5c6d7e8f90"],
            "PeerDevice rows are keyed by device and cascade from nothing"
        )
    }

    /// A contact with neither a pinned key nor device rows names nothing at any point. The prune
    /// must be a no-op over an empty set rather than a fallback to the account id — handing an
    /// account UUID to `forgetContactState` would ask the core about a contact it has never held.
    func testAContactWeCannotNameYieldsAnEmptySetNotTheAccountId() {
        makeUser(pinned: false)
        let devices = SessionAddressing.deviceIds(ofPeer: account, in: context)
        XCTAssertTrue(devices.isEmpty)
        XCTAssertFalse(devices.contains(account), "the account id is not a device and must never stand in for one")
    }
}
