//
//  TranscriptSealedAtRestTests.swift
//  ConstructMessengerTests
//
//  What was said in a voice message or video note, and the quote a reply carries, are stored
//  sealed with the row's storage key, as the body is — not in the plaintext `transcriptText` and
//  `replyToContent` columns they lived in until 2026-10-04 (vault TODO 115). These read the stored bytes, not only the round trip, because a round trip
//  through a plaintext column passes too.
//

import XCTest
import CoreData
@testable import Construct_Messenger

final class TranscriptSealedAtRestTests: XCTestCase {
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    private func row(withBody: Bool = true) -> Message {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        let row = Message(context: context)
        row.id = UUID().uuidString.lowercased()
        row.chat = chat
        row.timestamp = Date()
        row.serverOrderKey = ServerMessageOrder.local(timestamp: row.timestamp, messageId: row.id)
        row.fromUserId = "peer"
        row.toUserId = "me"
        row.isSentByMe = false
        if withBody {
            row.applyStoredEncryption(plaintextData: Data("a voice message".utf8), contactId: "peer")
        } else {
            row.encryptedContent = Data()
        }
        return row
    }

    private let said = "встречаемся у метро в семь"

    func testATranscriptIsStoredSealedAndReadsBack() throws {
        let message = row()
        message.transcript = said
        try context.save()

        XCTAssertNil(message.transcriptText, "nothing in the plaintext column")
        let sealed = try XCTUnwrap(message.encryptedTranscript)
        XCTAssertNil(sealed.range(of: Data(said.utf8)), "the stored bytes are not the text")
        let key = try XCTUnwrap(MessageKeyStore.shared.fetch(messageId: try XCTUnwrap(message.contentKeyRef)))
        XCTAssertEqual(String(data: try MessageStorageCrypto.decrypt(ciphertext: sealed, key: key), encoding: .utf8), said,
                       "sealed with the row's own storage key")
        XCTAssertEqual(message.transcript, said)
    }

    /// No key means no transcript — not a transcript in the clear.
    func testARowWithoutAStorageKeyKeepsNoTranscript() {
        let message = row(withBody: false)
        message.transcript = said
        XCTAssertNil(message.transcriptText)
        XCTAssertNil(message.encryptedTranscript)
    }

    func testClearingTheTranscriptClearsBothColumns() {
        let message = row()
        message.transcript = said
        message.transcript = nil
        XCTAssertNil(message.encryptedTranscript)
        XCTAssertNil(message.transcriptText)
    }

    /// Rows written before this change: the launch migration seals them and empties the column.
    func testTheMigrationSealsPlaintextTranscripts() throws {
        let legacy = row()
        legacy.transcriptText = said
        let keyless = row(withBody: false)
        keyless.transcriptText = said
        try context.save()

        StorageMigrationService.shared.sealPlaintextColumns(in: context)

        XCTAssertNil(legacy.transcriptText)
        XCTAssertNotNil(legacy.encryptedTranscript)
        XCTAssertEqual(legacy.transcript, said)
        XCTAssertNil(keyless.transcriptText, "dropped rather than kept in the clear")
        XCTAssertNil(keyless.encryptedTranscript)

        let left = Message.fetchRequest()
        left.predicate = NSPredicate(format: "transcriptText != nil")
        XCTAssertEqual(try context.count(for: left), 0)
    }

    func testAReplyQuoteIsStoredSealedAndReadsBack() throws {
        let message = row()
        message.replyQuote = said
        XCTAssertNil(message.replyToContent)
        let sealed = try XCTUnwrap(message.encryptedReplyQuote)
        XCTAssertNil(sealed.range(of: Data(said.utf8)))
        XCTAssertEqual(message.replyQuote, said)
    }

    func testTheMigrationSealsPlaintextQuotes() throws {
        let legacy = row()
        legacy.replyToContent = said
        try context.save()
        StorageMigrationService.shared.sealPlaintextColumns(in: context)
        XCTAssertNil(legacy.replyToContent)
        XCTAssertEqual(legacy.replyQuote, said)
    }

    /// An edit re-encrypts the body. It must reuse the row's key, or whatever else was sealed
    /// under the old one stops opening. Read through a fresh key lookup, not the opened cache.
    func testSealedFieldsSurviveTheBodyBeingReencrypted() throws {
        let message = row()
        message.transcript = said
        message.replyQuote = "the question"
        let keyBefore = MessageKeyStore.shared.fetch(messageId: message.id)

        message.applyStoredEncryption(plaintextData: Data("an edited body".utf8), contactId: "peer")

        let key = try XCTUnwrap(MessageKeyStore.shared.fetch(messageId: message.id))
        XCTAssertEqual(key, keyBefore, "one key for the row's life")
        XCTAssertEqual(String(data: try MessageStorageCrypto.decrypt(ciphertext: try XCTUnwrap(message.encryptedTranscript), key: key), encoding: .utf8), said)
        XCTAssertEqual(String(data: try MessageStorageCrypto.decrypt(ciphertext: try XCTUnwrap(message.encryptedReplyQuote), key: key), encoding: .utf8), "the question")
        XCTAssertEqual(message.displayText, "an edited body")
    }
}
