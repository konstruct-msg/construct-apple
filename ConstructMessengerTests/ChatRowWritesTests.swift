//
//  ChatRowWritesTests.swift
//  ConstructMessengerTests
//
//  The chat's list row — preview and unread count — is written through `ChatStore` after the
//  message's own save, never in the message's context (LOCAL_STORE_MIGRATION_PLAN, chats B2).
//  Each test names the mutation that must redden it.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class ChatRowWritesTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var chats: CoreDataChatStore!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useMessagesForTesting(container)
        chats = CoreDataChatStore(container: container)
    }

    override func tearDown() {
        LocalRepositories.useContactsForTesting(nil)
        LocalRepositories.useChatsForTesting(nil)
        LocalRepositories.useMessagesForTesting(nil)
        chats = nil
        container = nil
        super.tearDown()
    }

    private func openChat() throws -> Chat {
        try LocalRepositories.contacts.insert(.new(id: "peer", isContact: true, addedAt: nil))
        let id = try chats.openChat(withPeer: "peer", now: Date(timeIntervalSince1970: 1_000)).chat.id
        return try Chat.row(id, in: container.viewContext)
    }

    private func link(_ text: String, to chat: Chat) {
        let message = PreviewHelpers.createSampleMessage(
            context: container.viewContext, chat: chat, isSentByMe: false, text: text
        )
        message.fromUserId = "peer"
        message.toUserId = "me"
    }

    /// The view context holds the chat only to link messages to it. A repository write lands in
    /// another context; the view context's next save of a link — before the merge has landed —
    /// must neither fail nor put back the values it held. A background context with the default
    /// merge policy does fail here ("Could not merge changes", measured 2026-10-09), which is why
    /// the message path stays on the view context. Mutation: drop the view context's
    /// property-trump merge policy in `PersistenceController` — the save throws.
    func testARepositoryWriteSurvivesTheMessageContextsNextSave() throws {
        let chat = try openChat()
        link("one", to: chat)
        try container.viewContext.save()

        let later = Date(timeIntervalSince1970: 5_000)
        try chats.advancePreview(chat.id, text: "written by the repository", time: later)
        try chats.incrementUnread(chat.id)

        link("two", to: chat)
        XCTAssertNoThrow(try container.viewContext.save())

        let read = try XCTUnwrap(chats.chat(chat.id))
        XCTAssertEqual(read.lastMessageText, "written by the repository")
        XCTAssertEqual(read.lastMessageTime, later)
        XCTAssertEqual(read.unreadCount, 1)
    }

    /// A received message moves the list row: preview and one more unread. Mutation: drop the
    /// `incrementUnread` after the save in `saveMessage` — the count stays 0.
    func testASavedMessageMovesThePreviewAndCountsAsUnread() throws {
        let chat = try openChat()
        let incoming = ChatMessage(id: UUID().uuidString, from: "peer", to: "me", timestamp: 2_000)
        let isNew = try MessagePersistenceService().saveMessage(
            incoming, decryptedContent: "hello", isSentByMe: false, status: .delivered,
            chat: chat, suiteId: 1, in: container.viewContext
        )
        XCTAssertTrue(isNew)
        let read = try XCTUnwrap(chats.chat(chat.id))
        XCTAssertEqual(read.lastMessageText, "hello")
        XCTAssertEqual(read.lastMessageTime, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(read.unreadCount, 1)

        // Our own message moves the preview and is not unread.
        let outgoing = ChatMessage(id: UUID().uuidString, from: "me", to: "peer", timestamp: 3_000)
        _ = try MessagePersistenceService().saveMessage(
            outgoing, decryptedContent: "hi back", isSentByMe: true, status: .sent,
            chat: chat, suiteId: 1, in: container.viewContext
        )
        XCTAssertEqual(try chats.chat(chat.id)?.lastMessageText, "hi back")
        XCTAssertEqual(try chats.chat(chat.id)?.unreadCount, 1)
    }

    /// Deleting the newest message moves the preview back to the one left, and deleting the last
    /// clears it. Mutation: advance instead of set in `updateChatMetadataAfterDeletion` — the
    /// preview cannot move back and keeps the deleted message's text.
    func testDeletingTheNewestMovesThePreviewBack() throws {
        let chat = try openChat()
        let service = MessagePersistenceService()
        for (id, text, at) in [("m1", "first", 2_000), ("m2", "second", 3_000)] {
            _ = try service.saveMessage(
                ChatMessage(id: id, from: "peer", to: "me", timestamp: UInt64(at)),
                decryptedContent: text, isSentByMe: false, status: .delivered,
                chat: chat, suiteId: 1, in: container.viewContext
            )
        }
        XCTAssertEqual(try chats.chat(chat.id)?.lastMessageText, "second")
        try service.deleteMessages(withIds: ["m2"], chat: chat, in: container.viewContext)
        XCTAssertEqual(try chats.chat(chat.id)?.lastMessageText, "first")
        try service.deleteMessages(withIds: ["m1"], chat: chat, in: container.viewContext)
        XCTAssertNil(try chats.chat(chat.id)?.lastMessageTime)
    }

    /// A write of the values already there saves nothing — the chats list re-checks previews on
    /// every save, and an idle save would wake it again. Mutation: save whenever `update` ran.
    func testAWriteOfTheSameValuesSavesNothing() async throws {
        let chat = try openChat()
        try chats.setPreview(chat.id, text: "same", time: Date(timeIntervalSince1970: 2_000))
        var saves = 0
        let changes = chats.changes()
        let reading = Task { for await _ in changes { saves += 1 } }
        defer { reading.cancel() }
        try chats.setPreview(chat.id, text: "same", time: Date(timeIntervalSince1970: 2_000))
        try chats.setUnread(chat.id, 0)
        try chats.setPinned(chat.id, false)
        try chats.setPinned(chat.id, true)
        for _ in 0..<50 where saves == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(saves, 1, "only the pin that changed")
    }
}
