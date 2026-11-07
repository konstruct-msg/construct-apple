//
//  NewOwnDeviceReachesTheCopyListTests.swift
//  Construct Messenger
//
//  The list of our own devices is cached for an hour. A device of ours recorded in that hour must
//  not wait for it: the stand on 2026-11-07 sent two messages after a link and the new device got
//  neither copy, with nothing in the log (todo/275).
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

@MainActor
final class NewOwnDeviceReachesTheCopyListTests: XCTestCase {
    private let me = "e7a4e3d2-0000-4000-8000-0000000000aa"
    private let contact = "e7a4e3d2-0000-4000-8000-0000000000bb"

    override func setUp() async throws {
        try await super.setUp()
        SessionAddressing.ownAccountOverrideForTesting = me
        LocalRepositories.usePeerDevicesForTesting(
            CoreDataPeerDeviceStore(container: PersistenceController(inMemory: true).container)
        )
        MultiDeviceSendCoordinator.shared.holdOwnDeviceListForTesting()
    }

    override func tearDown() async throws {
        MultiDeviceSendCoordinator.shared.invalidateOwnDeviceCache()
        LocalRepositories.usePeerDevicesForTesting(nil)
        SessionAddressing.ownAccountOverrideForTesting = nil
        try await super.tearDown()
    }

    func testANewDeviceOfOursDropsTheCachedList() async {
        SessionAddressing.recordDevices([device()], ofPeer: me)

        await settle()

        XCTAssertFalse(MultiDeviceSendCoordinator.shared.ownDeviceListIsCached)
    }

    /// Every device of every contact would otherwise cost a fetch of our own list.
    func testAContactsNewDeviceLeavesItAlone() async {
        SessionAddressing.recordDevices([device()], ofPeer: contact)

        await settle()

        XCTAssertTrue(MultiDeviceSendCoordinator.shared.ownDeviceListIsCached)
    }

    /// A fetch records what it found. If a known device dropped the list too, the next send would
    /// fetch again, and so would every send after it.
    func testADeviceAlreadyRecordedLeavesItAlone() async {
        let known = device()
        SessionAddressing.recordDevices([known], ofPeer: me)
        await settle()
        MultiDeviceSendCoordinator.shared.holdOwnDeviceListForTesting()

        SessionAddressing.recordDevices([known], ofPeer: me)

        await settle()
        XCTAssertTrue(MultiDeviceSendCoordinator.shared.ownDeviceListIsCached)
    }

    // MARK: - Helpers

    private func device() -> (deviceId: String, identityKey: Data) {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        return (deriveDeviceId(identityPublicKey: key), key)
    }

    /// `recordDevices` hands the change to the main actor. Yielding here lets it run; the tests that
    /// expect nothing to happen need the same room, or they would pass on a change still queued.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
