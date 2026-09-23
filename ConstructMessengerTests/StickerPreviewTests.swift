//
//  StickerPreviewTests.swift
//  ConstructMessengerTests
//
//  The chat-list line for a sticker row survives every writer of `Chat.lastMessageText`. The
//  receive and send paths already read the payload's preview; the reconcilers read the row's
//  text form, which for a sticker is empty on purpose — so the first list refresh after a sticker
//  arrived wiped the line. Seen on the two-sim stand 2026-09-21: "idle albatross, 12:26", no text.
//

import CoreData
import XCTest
@testable import Construct_Messenger

final class StickerPreviewTests: XCTestCase {

    private func stickerPayload() -> Data {
        let ref = StickerReference(pack: StickerPackID(Data(repeating: 0x42, count: 32))!, index: 1, emoji: "🟥")!
        var c = Shared_Proto_Messaging_V1_MessageContent()
        c.sticker = ref.wire
        return LocalMessagePayload.storagePayload(forWireContent: c)
    }

    /// Mutation: point `reconcilePreviewFromTranscript` back at `displayText` — the line
    /// becomes "" and this reddens.
    func testReconcileFromTranscriptKeepsTheStickerLine() throws {
        let container = PersistenceController(inMemory: true).container
        let ctx = container.viewContext

        let chat = Chat(context: ctx)
        chat.id = UUID().uuidString
        let row = Message(context: ctx)
        row.id = UUID().uuidString.lowercased()
        row.chat = chat
        row.timestamp = Date()
        row.serverOrderKey = ServerMessageOrder.local(timestamp: row.timestamp, messageId: row.id)
        row.isSentByMe = false
        row.fromUserId = "peer"
        row.toUserId = "me"
        row.applyStoredEncryption(plaintextData: stickerPayload(), contactId: "peer")
        try ctx.save()

        XCTAssertEqual(row.displayText, "", "a sticker has no text form")
        XCTAssertEqual(row.previewText, "🟥 \(NSLocalizedString("sticker", comment: ""))")

        chat.clearPreview()
        XCTAssertTrue(chat.reconcilePreviewFromTranscript(in: ctx))
        XCTAssertEqual(chat.lastMessageText, "🟥 \(NSLocalizedString("sticker", comment: ""))")
    }
}
