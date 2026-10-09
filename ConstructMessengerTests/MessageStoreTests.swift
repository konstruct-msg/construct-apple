//
//  MessageStoreTests.swift
//  ConstructMessengerTests
//
//  What any `MessageStore` must answer — the same claims `construct-store`'s own tests make of
//  `LocalStore` (store_test.rs, messages domain), run against Core Data today. Each test names the
//  mutation that must redden it.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class MessageStoreTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var store: CoreDataMessageStore!
    private var chatId = ""

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        store = CoreDataMessageStore(container: container)
        try! CoreDataContactStore(container: container).insert(.new(id: "peer", isContact: true, addedAt: nil))
        chatId = try! CoreDataChatStore(container: container).openChat(withPeer: "peer").chat.id
    }

    override func tearDown() {
        store = nil
        container = nil
        super.tearDown()
    }

    private func record(_ id: String, key: String, body: String = "hello", mine: Bool = true) -> MessageRecord {
        MessageRecord(
            id: id, chatId: chatId, fromUserId: mine ? "me" : "peer", toUserId: mine ? "peer" : "me",
            isSentByMe: mine, timestamp: Date(timeIntervalSince1970: 1_000), orderKey: key,
            body: Data(body.utf8), contentType: .regular, deliveryStatus: .sending, retryCount: 0,
            suiteId: 4, isEdited: false, editedAt: nil, replyToMessageId: nil, replyQuote: nil,
            transcript: nil, transcriptLanguage: nil, transcriptGeneratedAt: nil
        )
    }

    /// Every field the record carries comes back, the sealed ones included. Mutation: write the
    /// quote before the body in `insert` — it is sealed under no key and reads back nil.
    func testAMessageReadsBackWhole() throws {
        var written = record("m1", key: "k1", body: "what it says")
        written.deliveryStatus = .sent
        written.retryCount = 2
        written.isEdited = true
        written.editedAt = Date(timeIntervalSince1970: 2_000)
        written.replyToMessageId = "m0"
        written.replyQuote = "the quote"
        written.transcript = "spoken words"
        written.transcriptLanguage = "en"
        written.transcriptGeneratedAt = Date(timeIntervalSince1970: 3_000)
        XCTAssertTrue(try store.insert(written, searchText: "what it says"))
        XCTAssertEqual(try store.message("m1"), written)
        XCTAssertEqual(try store.message("M1")?.id, "m1", "ids are compared without case")
        XCTAssertNil(try store.message("nothing"))
    }

    /// The body is sealed at rest in Core Data: the stored bytes are not what the message says.
    /// Mutation: store the payload as `encryptedContent` in the clear.
    func testTheBodyIsNotStoredInTheClear() throws {
        try store.insert(record("m1", key: "k1", body: "a secret sentence"), searchText: nil)
        let context = container.newBackgroundContext()
        let stored = try context.performAndWait { try XCTUnwrap(Message.row("m1", in: context)).encryptedContent }
        XCTAssertFalse(stored.isEmpty)
        XCTAssertNil(stored.range(of: Data("a secret sentence".utf8)))
    }

    /// One id, one message; a message needs its chat. Mutation: drop the existing-row check.
    func testAnIdIsOneMessageAndAMessageNeedsItsChat() throws {
        XCTAssertTrue(try store.insert(record("m1", key: "k1"), searchText: nil))
        XCTAssertFalse(try store.insert(record("M1", key: "k9", body: "again"), searchText: nil))
        XCTAssertEqual(try store.message("m1").map { String(decoding: $0.body, as: UTF8.self) }, "hello")
        var orphan = record("m2", key: "k2")
        orphan = MessageRecord(
            id: orphan.id, chatId: "no-such-chat", fromUserId: orphan.fromUserId, toUserId: orphan.toUserId,
            isSentByMe: true, timestamp: orphan.timestamp, orderKey: orphan.orderKey, body: orphan.body,
            contentType: .regular, deliveryStatus: .sending, retryCount: 0, suiteId: 4, isEdited: false,
            editedAt: nil, replyToMessageId: nil, replyQuote: nil, transcript: nil,
            transcriptLanguage: nil, transcriptGeneratedAt: nil
        )
        XCTAssertThrowsError(try store.insert(orphan, searchText: nil))
    }

    /// A transport failure is ignorance, not a negative result — the crate's rule, the same
    /// sequence as its `ignorance_never_overwrites_evidence`. Mutation: write `deliveryStatusRaw`
    /// directly in `setDeliveryStatus`.
    func testIgnoranceNeverOverwritesEvidence() throws {
        try store.insert(record("m1", key: "k1"), searchText: nil)
        let steps: [(DeliveryStatus, Bool)] = [
            (.queued, true), (.failed, true), (.sending, true), (.sent, true), (.queued, false),
            (.failed, false), (.delivered, true), (.sent, false), (.queued, false), (.delivered, false),
        ]
        for (status, lands) in steps {
            XCTAssertEqual(try store.setDeliveryStatus("m1", status), lands, "write \(status)")
        }
        XCTAssertEqual(try store.message("m1")?.deliveryStatus, .delivered)
        XCTAssertFalse(try store.setDeliveryStatus("nothing", .sent))
    }

    /// Keep the confirmed, queue the rest while attempts last, give up after. Mutation: apply
    /// `.resend` to a delivered message.
    func testASessionArchiveKeepsTheConfirmedAndRequeuesTheRest() throws {
        for id in ["m1", "m2", "m3"] { try store.insert(record(id, key: id), searchText: nil) }
        try store.setDeliveryStatus("m1", .delivered)
        try store.setDeliveryStatus("m2", .sent)
        try store.setDeliveryStatus("m3", .sent)
        try store.setRetryCount("m3", 3)
        XCTAssertEqual(try store.applySessionArchive("m1", maxRetries: 3), .keep)
        XCTAssertEqual(try store.applySessionArchive("m2", maxRetries: 3), .resend)
        XCTAssertEqual(try store.applySessionArchive("m3", maxRetries: 3), .giveUp)
        XCTAssertEqual(try ["m1", "m2", "m3"].map { try store.message($0)?.deliveryStatus },
                       [.delivered, .queued, .failed])
        XCTAssertNil(try store.applySessionArchive("nothing", maxRetries: 3))
    }

    /// Each write changes its fields and nothing else; the same value again reports false.
    /// Mutation: reset `retryCount` from `setOrderKey`.
    func testEachMessageWriteChangesOnlyItsFields() throws {
        var expected = record("m1", key: "k1")
        try store.insert(expected, searchText: nil)
        XCTAssertTrue(try store.setRetryCount("m1", 2)); expected.retryCount = 2
        XCTAssertTrue(try store.setOrderKey("m1", "server-7")); expected.orderKey = "server-7"
        XCTAssertEqual(try store.incrementRetryCount("m1"), 3); expected.retryCount = 3
        let at = Date(timeIntervalSince1970: 9)
        XCTAssertTrue(try store.setTranscript("m1", text: "hi", language: "en", generatedAt: at))
        expected.transcript = "hi"; expected.transcriptLanguage = "en"; expected.transcriptGeneratedAt = at
        XCTAssertEqual(try store.message("m1"), expected)

        XCTAssertFalse(try store.setOrderKey("m1", "server-7"))
        XCTAssertFalse(try store.setRetryCount("m1", 3))
        XCTAssertNil(try store.incrementRetryCount("nothing"))
    }

    /// An edit replaces what the message says and marks it. Mutation: leave `isEdited` alone.
    func testAnEditReplacesTheBody() throws {
        try store.insert(record("m1", key: "k1", body: "first"), searchText: nil)
        let at = Date(timeIntervalSince1970: 5)
        XCTAssertTrue(try store.edit("m1", body: Data("second".utf8), searchText: "second", editedAt: at))
        let read = try XCTUnwrap(store.message("m1"))
        XCTAssertEqual(String(decoding: read.body, as: UTF8.self), "second")
        XCTAssertTrue(read.isEdited)
        XCTAssertEqual(read.editedAt, at)
        XCTAssertFalse(try store.edit("nothing", body: Data(), searchText: nil, editedAt: at))
    }

    /// Pages run back through the transcript, oldest first in a page. Mutation: drop the
    /// `before` condition — the earlier page repeats the newest.
    func testPagesRunBackOldestFirst() throws {
        for i in 1...5 { try store.insert(record("m\(i)", key: "k\(i)"), searchText: nil) }
        let newest = try store.messages(inChat: chatId, before: nil, limit: 2)
        XCTAssertEqual(newest.map(\.id), ["m4", "m5"])
        let earlier = try store.messages(inChat: chatId, before: ("k4", "m4"), limit: 2)
        XCTAssertEqual(earlier.map(\.id), ["m2", "m3"])
    }

    /// Deleted messages are gone; others stay. Mutation: delete the whole chat's messages.
    func testDeletingRemovesOnlyTheNamed() throws {
        for i in 1...3 { try store.insert(record("m\(i)", key: "k\(i)"), searchText: nil) }
        try store.delete(["m1", "M3"])
        XCTAssertNil(try store.message("m1"))
        XCTAssertNil(try store.message("m3"))
        XCTAssertNotNil(try store.message("m2"))
    }

    /// Writes are announced by message id. Mutation: return `nil` for a `Message` in the feed.
    func testWritesAreAnnounced() async throws {
        var seen = Set<String>()
        let changes = store.changes()
        let reading = Task { for await ids in changes { seen.formUnion(ids) } }
        defer { reading.cancel() }
        try store.insert(record("m1", key: "k1"), searchText: nil)
        try store.setDeliveryStatus("m1", .sent)
        for _ in 0..<200 where !seen.contains("m1") { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(seen.contains("m1"))
    }
}
