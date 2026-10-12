//
//  IncomingMessageChatTests.swift
//  ConstructMessengerTests
//
//  Where a received message lands, now that the receive path names its chat by id and makes it
//  through the repositories (2026-10-12). Until then `Chat.findOrCreate` made the chat in the
//  router's context before anything was decided, and deleted it again on fifteen early exits.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class IncomingMessageChatTests: XCTestCase {

    private var container: NSPersistentContainer!
    private let sender = "21111111-2222-4333-8444-555555555555"

    override func setUpWithError() throws {
        try CryptoCoreTestBootstrap.ensureCore(localUserId: "1a2b3c4d-0000-4000-8000-000000000001")
        container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useMessagesForTesting(container)
        LocalRepositories.useProcessedMessagesForTesting(CoreDataProcessedMessageStore(container: container))
    }

    override func tearDown() {
        LocalRepositories.useContactsForTesting(nil)
        LocalRepositories.useChatsForTesting(nil)
        LocalRepositories.useMessagesForTesting(nil)
        LocalRepositories.useProcessedMessagesForTesting(nil)
        container = nil
        super.tearDown()
    }

    private func receive(_ text: String, id: String, at seconds: UInt64) throws {
        try MessageRouter()._testPersistRegularIncomingMessage(
            text,
            message: ChatMessage(id: id, from: sender, to: "me", timestamp: seconds),
            from: sender,
            in: container.viewContext
        )
    }

    /// A first message from someone we hold nothing for makes their contact and one chat, and the
    /// chat's row shows the message at the message's own time — an hour ago is still an hour ago.
    /// A second message goes into the same chat.
    ///
    /// Mutation: open the chat with `now` in `MessageRouter.chatId(forPeer:)` — the preview keeps
    /// the time of opening and refuses the older message.
    func testAFirstMessageMakesTheContactAndOneChatAtTheMessagesTime() throws {
        let sent = UInt64(Date().timeIntervalSince1970) - 3_600
        try receive("hello", id: "first", at: sent)
        try receive("again", id: "second", at: sent + 1)

        XCTAssertNotNil(try LocalRepositories.contacts.contact(sender))
        let chats = try LocalRepositories.chats.chats()
        XCTAssertEqual(chats.map(\.peerId), [sender])
        let chat = try XCTUnwrap(chats.first)
        XCTAssertEqual(chat.lastMessageText, "again")
        XCTAssertEqual(chat.lastMessageTime, Date(timeIntervalSince1970: TimeInterval(sent + 1)))
        XCTAssertEqual(chat.unreadCount, 2)
        XCTAssertEqual(try LocalRepositories.messages.messageCount(inChat: chat.id), 2)
    }
}
