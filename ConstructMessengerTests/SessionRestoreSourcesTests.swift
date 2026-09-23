//
//  SessionRestoreSourcesTests.swift
//  ConstructMessengerTests
//
//  Where the restore plan gets its ids, and what space those ids are in.
//
//  `SessionRestorePlanTests` covers the order the plan puts them in. This covers the half that
//  produced them, which was still account-space on one side and three-shapes-deep on the other.
//
//  Both testers' logs on 2026-09-23 (build 687, France and RF) said so in the only way the app
//  could: `restoreSession(for:) was handed <id>… — an account id where a device id is required`,
//  forty times between them, with `Session restore: 1 restored, 4 failed` and `14 restored,
//  10 failed` underneath. A session that is not restored is not lost quietly — a peer's is
//  rebuilt by the next `messageNumber == 0`, an own device's is rebuilt by nothing.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class SessionRestoreSourcesTests: XCTestCase {

    // MARK: - The chat list is account-space and must not stay that way

    /// Mutation: return `$0.otherUser?.id` from `getRecentChatDeviceIds` without the expansion —
    /// this reddens with the account in the list, which is exactly what the logs showed.
    func testAChatContributesItsPeersDevicesAndNeverTheAccount() {
        let container = PersistenceController(inMemory: true).container
        let context = container.viewContext

        let account = "bcb7d060-f342-40fa-9054-3fd5de035041"
        let phone   = "b26a2cf863f7db482ed0f2963933b86c"
        let desktop = "651e765cbbd33b4e48631fb802c2b3d2"

        let user = User(context: context)
        user.id = account
        user.username = "annie"
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        chat.lastMessageTime = Date()
        for (index, deviceId) in [phone, desktop].enumerated() {
            let row = PeerDevice(context: context)
            row.accountId = account
            row.deviceId = deviceId
            row.firstSeenAt = Date(timeIntervalSince1970: TimeInterval(1_000 + index))
        }
        try? context.save()

        let ids = SessionRestoreService(persistence: .shared)
            .getRecentChatDeviceIds(limit: 20, context: context)

        XCTAssertEqual(Set(ids), [phone, desktop], "both of the peer's devices, and only devices")
        XCTAssertFalse(ids.contains(account), "an account id below the seam is the defect itself")
        for id in ids {
            XCTAssertNotNil(
                SessionAddressing.asDevice(id),
                "\(id) would be refused by the very call this list feeds"
            )
        }
    }

    /// A peer whose device set has never been fetched still has to be restorable: the pinned
    /// identity key is the offline answer, and dropping the chat entirely would trade one
    /// silent failure for another.
    func testAPeerWithNoRecordedDevicesDoesNotSilentlyVanish() {
        let container = PersistenceController(inMemory: true).container
        let context = container.viewContext

        let user = User(context: context)
        user.id = "9a921fe2-0f5e-4a2f-9a3f-0f0b4f2a1c77"
        user.username = "bob"
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        chat.lastMessageTime = Date()
        try? context.save()

        let ids = SessionRestoreService(persistence: .shared)
            .getRecentChatDeviceIds(limit: 20, context: context)

        // No `PeerDevice` rows and no pinned key in this store, so the honest result is empty —
        // not the account. The assertion is about which of the two it is.
        XCTAssertFalse(ids.contains(user.id), "an unresolvable peer yields nothing, never an account")
    }

    // MARK: - The session store holds three shapes and can restore one

    private let device = "b26a2cf863f7db482ed0f2963933b86c"
    private let account = "bcb7d060-f342-40fa-9054-3fd5de035041"

    /// Mutation: drop the `isCryptoIdentity` branch and keep every `contactId` — this reddens,
    /// and it is the code that shipped: the pair and the legacy account went to `restoreSession`
    /// and came back as an `ERROR` each, on every launch.
    func testOnlyDeviceKeyedEntriesAreOfferedForRestore() {
        let held = LiveSessionAccounts.classify([
            "session_\(device)",
            "session_\(account)",
            "session_\(account):\(device)",
        ])
        XCTAssertEqual(held.deviceIds, [device])
        XCTAssertEqual(held.strandedPairs, 1)
        XCTAssertEqual(held.strandedAccounts, 1)
    }

    /// Archives are session state but not live sessions, and restoring one would resurrect a
    /// ratchet that END_SESSION retired.
    func testArchivesAreNotRestored() {
        let held = LiveSessionAccounts.classify([
            "session_archives_\(device)",
            "session_\(device)",
        ])
        XCTAssertEqual(held.deviceIds, [device])
        XCTAssertEqual(held.strandedPairs + held.strandedAccounts, 0)
    }

    /// The namespace has other tenants; a restore must not reach into them.
    func testForeignAccountsAreNotCounted() {
        let held = LiveSessionAccounts.classify([
            "construct.orchestrator_state",
            "construct.kyber.spk.sk.\(device)",
            "session_\(device)",
        ])
        XCTAssertEqual(held.deviceIds, [device])
        XCTAssertEqual(held.strandedPairs + held.strandedAccounts, 0,
                       "counting a neighbour as a stranded session would invent a migration")
    }
}
