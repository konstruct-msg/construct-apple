//
//  SenderSyncReplyQuoteTests.swift
//  ConstructMessengerTests
//
//  A reply written on our other device arrives here as SENDER_SYNC, and is a reply here too.
//  Until 2026-10-20 that path stored the row with no reply id and no quote (TODO 177).
//

import CoreData
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

@MainActor
final class SenderSyncReplyQuoteTests: XCTestCase {
    private var container: NSPersistentContainer!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        LocalRepositories.useContactsForTesting(container)
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useMessagesForTesting(container)
    }

    override func tearDown() {
        LocalRepositories.useContactsForTesting(nil)
        LocalRepositories.useChatsForTesting(nil)
        LocalRepositories.useMessagesForTesting(nil)
        container = nil
        super.tearDown()
    }

    private func synced(_ text: String, quoting quoted: Shared_Proto_Messaging_V1_QuotedMessage?) throws -> MessageRecord? {
        var message = Shared_Proto_Messaging_V1_TextMessage()
        message.text = text
        if let quoted { message.quoted = quoted }
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.text = message
        let id = UUID().uuidString.lowercased()
        let original = ChatMessage(id: id, from: "me", to: "me", timestamp: 2_000)
        MessageRouter()._testSaveSenderSyncMessage(
            try content.serializedData(), original: original,
            partnerUserId: "8a0c1f6e-0000-0000-0000-000000000009", in: container.viewContext
        )
        return try LocalRepositories.messages.message(id)
    }

    /// Mutation: store `replyToMessageId: nil, replyQuote: nil` on the SENDER_SYNC path again —
    /// both assertions redden.
    func testAReplyFromOurOtherDeviceKeepsItsQuote() throws {
        var quoted = Shared_Proto_Messaging_V1_QuotedMessage()
        quoted.messageID = "8A0C1F6E-0000-0000-0000-00000000000A"
        quoted.textPreview = "the question"
        let row = try XCTUnwrap(try synced("the answer", quoting: quoted))
        XCTAssertEqual(row.replyToMessageId, "8a0c1f6e-0000-0000-0000-00000000000a")
        XCTAssertNotNil(row.replyQuote)
    }

    func testAMessageThatIsNotAReplyStaysOne() throws {
        let row = try XCTUnwrap(try synced("plain", quoting: nil))
        XCTAssertNil(row.replyToMessageId)
        XCTAssertNil(row.replyQuote)
    }
}
