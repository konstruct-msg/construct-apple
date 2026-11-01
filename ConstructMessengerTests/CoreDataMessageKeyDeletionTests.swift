import CoreData
import SQLite3
import XCTest
@testable import Construct_Messenger

@MainActor
final class CoreDataMessageKeyDeletionTests: XCTestCase {
    private var container: NSPersistentContainer!
    private var messages: CoreDataMessageStore!
    private var chats: CoreDataChatStore!
    private var contacts: CoreDataContactStore!
    private var keyRefs = Set<String>()
    private var messageIds = Set<String>()

    override func setUp() async throws {
        try await super.setUp()
        container = PersistenceController(inMemory: true).container
        messages = CoreDataMessageStore(container: container)
        chats = CoreDataChatStore(container: container)
        contacts = CoreDataContactStore(container: container)
        for peer in ["peer", "other"] {
            try contacts.insert(.new(id: peer, isContact: true, addedAt: nil))
        }
        // Current inserts prohibit duplicates; reproduce the two chats an older build left.
        let context = container.viewContext
        for (id, peer) in [("a", "peer"), ("b", "peer"), ("c", "other")] {
            let chat = Chat(context: context)
            chat.id = id
            chat.otherUser = try User.row(peer, in: context)
        }
        try context.save()
    }

    override func tearDown() async throws {
        for ref in keyRefs {
            MessageKeyStore.shared.delete(messageId: ref)
            _ = MessageKeyStore.shared.fetch(messageId: ref) // drain only our queued cleanup
        }
        for id in messageIds { MessageDisplayCache.shared.evict(messageId: id) }
        messages = nil
        chats = nil
        contacts = nil
        container = nil
        keyRefs.removeAll()
        messageIds.removeAll()
        try await super.tearDown()
    }

    /// TODO 250: deleting a row left both its storage key and any cached plaintext behind.
    /// Use a reference different from the row id, and keep another message of the same peer.
    func testDeletingAMessageRemovesItsReferencedKeyAndKeepsTheOthers() throws {
        let gone = try seed(in: "a")
        let kept = try seed(in: "a")
        let ref = "ref-\(UUID().uuidString)"
        keyRefs.insert(ref)
        let key = try XCTUnwrap(MessageKeyStore.shared.fetch(messageId: gone))
        MessageKeyStore.shared.storeSync(messageId: ref, key: key, contactId: "peer")
        let context = container.viewContext
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", gone)
        let row = try XCTUnwrap(context.fetch(request).first)
        row.contentKeyRef = ref
        try context.save()
        MessageKeyStore.shared.delete(messageId: gone)
        XCTAssertNil(MessageKeyStore.shared.fetch(messageId: gone))
        XCTAssertEqual(MessageKeyStore.shared.fetch(messageId: ref), key)

        try messages.delete([gone.uppercased()])

        XCTAssertNil(try messages.message(gone))
        assertGone(id: gone, ref: ref)
        try assertKept(kept)
    }

    /// A chat deletion cascades, but another chat of the same peer must keep its keys.
    func testDeletingAChatRemovesOnlyItsMessagesKeysAndCachedBodies() throws {
        let gone = try seed(in: "a")
        let kept = try seed(in: "b")
        try chats.delete("a")

        XCTAssertNil(try chats.chat("a"))
        XCTAssertNotNil(try contacts.contact("peer"))
        assertGone(id: gone, ref: gone)
        try assertKept(kept)
    }

    /// Contact -> every chat -> every message, including duplicate chats left by older builds.
    func testDeletingAContactRemovesAllItsMessagesKeysAndKeepsOtherContacts() throws {
        let gone = [try seed(in: "a"), try seed(in: "b")]
        let kept = try seed(in: "c")
        XCTAssertTrue(try contacts.delete("peer"))

        for id in gone { assertGone(id: id, ref: id) }
        XCTAssertNil(try chats.chat("a"))
        XCTAssertNil(try chats.chat("b"))
        try assertKept(kept)
    }

    /// The save really fails validation; this is not a mock that skips the production ordering.
    func testARefusedCoreDataSaveKeepsTheKeyAndCachedBody() throws {
        let id = try seed(in: "a")
        let context = container.viewContext
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        let row = try XCTUnwrap(context.fetch(request).first)
        let invalid = User(context: context)
        invalid.username = ""
        invalid.displayName = ""
        // id is mandatory in the real model. The unrelated invalid insert refuses the save.
        XCTAssertNil(invalid.value(forKey: "id"))
        XCTAssertThrowsError(try CoreDataMessageDeletion.delete([row], in: context, category: "Test"))
        context.rollback()

        XCTAssertNotNil(MessageDisplayCache.shared.cachedPayload(messageId: id))
        try assertKept(id)
    }

    func testALegacyRowWithoutAKeyStillDeletesAndEvictsItsBody() throws {
        let id = try seed(in: "a")
        let context = container.viewContext
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        let row = try XCTUnwrap(context.fetch(request).first)
        row.contentKeyRef = nil
        row.decryptedContent = id
        try context.save()
        MessageKeyStore.shared.delete(messageId: id)
        XCTAssertNil(MessageKeyStore.shared.fetch(messageId: id))

        try messages.delete([id])

        XCTAssertNil(try messages.message(id))
        XCTAssertNil(MessageDisplayCache.shared.cachedPayload(messageId: id))
    }

    /// A real SQLite writer lock, not a mock: key deletion must not silently accept SQLITE_BUSY.
    func testAKeyDatabaseWriteFailureIsReportedAndKeepsTheKey() throws {
        let id = try seed(in: "a")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(MessageKeyStore.storageURL.path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        do {
            defer { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
            XCTAssertThrowsError(try MessageKeyStore.shared.delete(messageIds: [id])) { error in
                guard case MessageKeyStore.DeletionError.sqlite(code: SQLITE_BUSY) = error else {
                    return XCTFail("Expected the real SQLite writer conflict, got \(error)")
                }
            }
        }
        try assertKept(id)
    }

    private func seed(in chatId: String) throws -> String {
        let id = UUID().uuidString.lowercased()
        messageIds.insert(id)
        keyRefs.insert(id)
        let peer = try XCTUnwrap(chats.chat(chatId)?.peerId)
        let record = MessageRecord(
            id: id, chatId: chatId, fromUserId: "me", toUserId: peer, isSentByMe: true,
            timestamp: Date(timeIntervalSince1970: 1_000), orderKey: id, body: Data(id.utf8),
            contentType: .regular, deliveryStatus: .sending, retryCount: 0, suiteId: 4,
            isEdited: false, editedAt: nil, replyToMessageId: nil, replyQuote: nil, transcript: nil,
            transcriptLanguage: nil, transcriptGeneratedAt: nil
        )
        XCTAssertTrue(try messages.insert(record, searchText: nil))
        XCTAssertNotNil(MessageKeyStore.shared.fetch(messageId: id))
        XCTAssertNotNil(MessageDisplayCache.shared.cachedPayload(messageId: id))
        return id
    }

    private func assertGone(id: String, ref: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(MessageKeyStore.shared.fetch(messageId: ref), file: file, line: line)
        XCTAssertNil(MessageKeyStore.shared.storedBlobForTesting(messageId: ref), file: file, line: line)
        XCTAssertNil(MessageDisplayCache.shared.cachedPayload(messageId: id), file: file, line: line)
    }

    private func assertKept(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNotNil(MessageKeyStore.shared.fetch(messageId: id), file: file, line: line)
        MessageDisplayCache.shared.evict(messageId: id)
        XCTAssertEqual(try messages.message(id)?.body, Data(id.utf8), file: file, line: line)
    }
}
