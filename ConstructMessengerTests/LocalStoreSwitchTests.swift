//
//  LocalStoreSwitchTests.swift
//  ConstructMessengerTests
//
//  What macOS runs on since TODO 137 step 4: every repository on one `LocalStore`. The contract
//  tests check each repository alone; these drive a path across them, and the store a failed open
//  leaves the repositories on.
//

import CoreData
import XCTest
@testable import Construct_Messenger

final class LocalStoreSwitchTests: XCTestCase {

    @MainActor
    override func setUpWithError() throws {
        try CryptoCoreTestBootstrap.ensureCore(localUserId: "1a2b3c4d-0000-4000-8000-000000000001")
    }

    override func tearDown() {
        LocalRepositories.useLocalStoreForTesting(nil)
        super.tearDown()
    }

    /// A received message lands whole on the crate: the sender becomes a row, their chat is opened
    /// and moved, the message is stored, and only then is the envelope marked processed.
    ///
    /// Mutation: leave `processedMessages` out of `Backing.localStore` (Core Data's) — the mark is
    /// not in the crate and the last assertion reddens.
    @MainActor
    func testAReceivedMessageLandsWholeOnTheCrate() throws {
        let session = LocalStoreSession.inMemoryForTesting()
        LocalRepositories.useLocalStoreForTesting(session)
        let sender = "14f28d31-aaaa-4bbb-8ccc-000000000001"
        let messageId = "8B403CE9-0000-4000-8000-\(String(UUID().uuidString.suffix(12)))"

        try MessageRouter()._testPersistRegularIncomingMessage(
            "hello on the crate",
            message: ChatMessage(id: messageId, from: sender, to: "me", timestamp: UInt64(Date().timeIntervalSince1970)),
            from: sender,
            in: PersistenceController(inMemory: true).container.viewContext
        )

        XCTAssertNotNil(try session.store.contact(id: sender), "the sender is a row")
        let chat = try XCTUnwrap(session.store.chatForPeer(peerId: sender), "the sender's chat")
        XCTAssertEqual(chat.unreadCount, 1)
        XCTAssertEqual(chat.lastMessageText, "hello on the crate")
        let stored = try XCTUnwrap(session.store.message(id: messageId.lowercased()))
        XCTAssertEqual(stored.chatId, chat.id)
        XCTAssertEqual(LocalMessagePayload.decode(stored.body).plainText, "hello on the crate")
        XCTAssertTrue(try session.store.isProcessed(messageId: messageId))
    }

    /// The store a failed open leaves behind takes nothing: the write throws where it is made, so
    /// the envelope is not marked processed and the server delivers it again once the store opens.
    ///
    /// Mutation: open an in-memory store and leave it open in `closed()` — the receive succeeds into
    /// memory, the mark is claimed, and the message is gone at the next launch.
    @MainActor
    func testAClosedStoreTakesNoReceiveAndClaimsNoAck() throws {
        LocalRepositories.useLocalStoreForTesting(.closed())
        let sender = "14f28d31-aaaa-4bbb-8ccc-000000000002"
        let messageId = "closed-\(UUID().uuidString)"

        XCTAssertThrowsError(try MessageRouter()._testPersistRegularIncomingMessage(
            "nowhere to go",
            message: ChatMessage(id: messageId, from: sender, to: "me", timestamp: UInt64(Date().timeIntervalSince1970)),
            from: sender,
            in: PersistenceController(inMemory: true).container.viewContext
        ))
        XCTAssertFalse(PersistentACKStore.shared.isProcessedInMemory(messageId))
    }

    /// A wiped store ends the streams the screens read: a list waiting on the old store's changes
    /// is not left waiting forever after the store under it was replaced.
    ///
    /// Mutation: drop `feed.finishAll()` from `wipe()` — the loop never ends and this times out.
    func testAWipeEndsEveryChangeStream() async throws {
        let session = LocalStoreSession.inMemoryForTesting()
        let changes = session.changes(of: .chats)
        let ended = Task { for await _ in changes {}; return true }
        try session.wipe()
        let didEnd = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await ended.value }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return false }
            let first = await group.next() ?? false
            // A stream that did not end is ended here, or the group waits on it.
            ended.cancel()
            group.cancelAll()
            return first
        }
        XCTAssertTrue(didEnd)
    }
}

/// The files Core Data builds left go; the store that replaced them and anything else stay.
final class LegacyStoreRemovalTests: XCTestCase {

    /// Mutation: drop the `-wal` name — the transcript's latest writes stay on disk and this
    /// reddens.
    func testTheOldStoreAndItsKeysGoAndNothingElse() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("ct_secure"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".ConstructMessenger_SUPPORT/_EXTERNAL_DATA"),
                               withIntermediateDirectories: true)
        for name in ["ConstructMessenger.sqlite", "ConstructMessenger.sqlite-wal", "ConstructMessenger.sqlite-shm",
                     "ct_secure/message_keys.sqlite", "construct.db", "whisper-models"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        XCTAssertEqual(PersistenceController.removeLegacyStore(in: dir), 5)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).sorted(), ["construct.db", "ct_secure", "whisper-models"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("ct_secure").path), [])
        XCTAssertEqual(PersistenceController.removeLegacyStore(in: dir), 0, "nothing left to remove")
    }
}
