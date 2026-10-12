//
//  TranscriptWindowTests.swift
//  ConstructMessengerTests
//
//  The open chat's transcript as values over `MessageStore` (local-store plan, lane C): which rows
//  it shows, how the window grows, and that every write the store reports reaches the row.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class TranscriptWindowTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var store: CoreDataMessageStore!
    private var chatId = ""
    private var otherChatId = ""

    override func setUp() async throws {
        container = PersistenceController(inMemory: true).container
        store = CoreDataMessageStore(container: container)
        // A row's text is read by id through the app's message store on a cache miss.
        LocalRepositories.useMessagesForTesting(container)
        let contacts = CoreDataContactStore(container: container)
        let chats = CoreDataChatStore(container: container)
        try contacts.insert(.new(id: "peer", isContact: true, addedAt: nil))
        try contacts.insert(.new(id: "other", isContact: true, addedAt: nil))
        chatId = try chats.openChat(withPeer: "peer").chat.id
        otherChatId = try chats.openChat(withPeer: "other").chat.id
    }

    override func tearDown() async throws {
        LocalRepositories.useMessagesForTesting(nil)
        MessageDisplayCache.shared.evictAll()
        store = nil
        container = nil
    }

    private func key(_ n: Int) -> String { String(format: "k%05d", n) }

    @discardableResult
    private func add(_ n: Int, body: String? = nil, type: MessageContentType = .regular, chat: String? = nil,
                     status: DeliveryStatus = .delivered) throws -> String {
        let id = String(format: "m%05d", n)
        try store.insert(MessageRecord(
            id: id, chatId: chat ?? chatId, fromUserId: "peer", toUserId: "me", isSentByMe: false,
            timestamp: Date(timeIntervalSince1970: TimeInterval(n)), orderKey: key(n),
            body: LocalMessagePayload.encodeText(body ?? "message \(n)"), contentType: type,
            deliveryStatus: status, retryCount: 0, suiteId: 4, isEdited: false, editedAt: nil,
            replyToMessageId: nil, replyQuote: nil, transcript: nil, transcriptLanguage: nil,
            transcriptGeneratedAt: nil
        ), searchText: nil)
        return id
    }

    private func open() -> TranscriptWindow {
        let window = TranscriptWindow(chatId: chatId, store: store, debounce: .zero)
        window.start()
        return window
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "not reached in 2 s", file: file, line: line)
    }

    private func ids(_ range: ClosedRange<Int>) -> [String] { range.map { String(format: "m%05d", $0) } }

    /// The newest page, oldest first; older pages join it until history ends.
    /// Mutation: leave `hasMore` as it was when a page comes back empty — the last assertion
    /// reddens.
    func testTheNewestPageThenOlderOnes() throws {
        for n in 1...45 { try add(n) }
        let window = open()
        XCTAssertEqual(window.rows.map(\.id), ids(16...45))
        XCTAssertTrue(window.hasMore)
        window.loadMore()
        XCTAssertEqual(window.rows.map(\.id), ids(1...45))
        XCTAssertFalse(window.hasMore)
    }

    /// A control signal, a text delivery receipt and a non-regular row are never rows — and a run
    /// of them at the tip does not open the chat short of a page.
    /// Mutation: drop the receipt check in `visible` — the receipt shows; read one page only in
    /// `readFirstPage` — the window opens with fewer rows.
    func testWhatIsNeverABubbleIsNotARow() throws {
        for n in 1...30 { try add(n) }
        try add(31, body: "__session_ping")
        try add(32, body: #"{"type":"delivery_receipt","ids":["x"]}"#)
        for n in 33...62 { try add(n, type: .sessionReset) }
        let window = open()
        XCTAssertEqual(window.rows.map(\.id), ids(1...30))
    }

    /// A message written while the chat is open appears; one written to another chat does not;
    /// rows loaded earlier stay — the window grows, it does not slide.
    /// Mutation: re-read the newest page on a change instead of the window — the loaded older rows
    /// drop out.
    func testANewMessageJoinsAndTheWindowDoesNotSlide() async throws {
        for n in 1...40 { try add(n) }
        let window = open()
        window.loadMore()
        XCTAssertEqual(window.rows.count, 40)
        try add(41)
        try add(42, chat: otherChatId)
        await eventually { window.rows.last?.id == "m00041" }
        XCTAssertEqual(window.rows.map(\.id), ids(1...41))
    }

    /// Every write the store reports reaches its row: a status in a field, and a body read late —
    /// which changes no field — in the revision, with the new text read through.
    /// Mutation: skip the revision bump in `changed` — the late body's row compares equal and is
    /// not redrawn.
    func testEveryWriteReachesItsRow() async throws {
        let id = try add(1, body: "", status: .sending)
        let window = open()
        let before = try XCTUnwrap(window.rows.first)
        XCTAssertEqual(before.readableText, "")

        try store.setDeliveryStatus(id, .sent)
        await eventually { window.rows.first?.deliveryStatus == .sent }

        let statusRevision = try XCTUnwrap(window.rows.first?.revision)
        try store.setBody(id, body: LocalMessagePayload.encodeText("read late"), searchText: nil)
        await eventually { (window.rows.first?.revision ?? 0) > statusRevision }
        XCTAssertEqual(window.rows.first?.readableText, "read late")
    }

    /// A write to a row reaches that row's entry and leaves the list alone: nothing observing
    /// `entries` hears it, and the entry is the same object. Only a new or a gone row republishes
    /// the list. Mutation: assign `entries` on every publish — the list observer fires.
    func testAStatusChangesItsEntryAndNotTheList() async throws {
        let id = try add(1, status: .sending)
        try add(2)
        let window = open()
        let entry = try XCTUnwrap(window.entries.first)

        var listChanged = false
        withObservationTracking { _ = window.entries } onChange: { listChanged = true }
        try store.setDeliveryStatus(id, .sent)
        await eventually { entry.row.deliveryStatus == .sent }
        XCTAssertFalse(listChanged, "a status is one row's business")
        XCTAssertTrue(window.entries.first === entry)

        try add(3)
        await eventually { window.entries.count == 3 }
        XCTAssertTrue(listChanged, "a new row is the list's")
    }

    /// A row carries no text: emptied as `UnsealedMemory` empties it, the text is read again from
    /// the store by id. Mutation: return an empty payload on a cache miss — the text is gone.
    func testARowsTextIsReadByIdWhenTheCacheIsEmptied() throws {
        try add(1, body: "kept in the store")
        let window = open()
        MessageDisplayCache.shared.evictAll()
        XCTAssertNil(MessageDisplayCache.shared.cachedPayload(messageId: "m00001"))
        XCTAssertEqual(window.rows.first?.readableText, "kept in the store")
    }

    /// History that went while the chat was open — deleted from another device's sync, say — ends
    /// the paging rather than leaving a spinner that never loads. Mutation: leave `hasMore` as it
    /// was when the older page comes back empty.
    func testLoadingMoreWhenTheOlderRowsAreGoneEndsThePaging() throws {
        for n in 1...31 { try add(n) }
        let window = open()
        XCTAssertTrue(window.hasMore)
        try store.delete(["m00001"])
        window.loadMore()
        XCTAssertFalse(window.hasMore)
        XCTAssertEqual(window.rows.count, 30)
    }

    /// The rows a read decrypted are not read again to be shown: the window's own read is the
    /// only one. Mutation: drop `hold` in `publish` — every bubble's text is a second read.
    func testShowingTheRowsReadsNothingAgain() throws {
        for n in 1...5 { try add(n) }
        let counting = CountingMessageStore(store)
        MessageDisplayCache.shared.evictAll()
        LocalRepositories.useMessagesForTesting(counting)
        let window = TranscriptWindow(chatId: chatId, store: counting, debounce: .zero)
        window.start()
        for row in window.rows { _ = row.readableText; _ = row.replyQuote; _ = row.transcript }
        XCTAssertEqual(counting.singleReads, 0)
    }
}

/// A message store that counts the one-message reads a cache miss makes.
private final class CountingMessageStore: MessageStore, @unchecked Sendable {
    private let base: any MessageStore
    private(set) var singleReads = 0
    init(_ base: any MessageStore) { self.base = base }

    func message(_ id: String) throws -> MessageRecord? { singleReads += 1; return try base.message(id) }
    func messages(inChat chatId: String, before: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord] {
        try base.messages(inChat: chatId, before: before, limit: limit)
    }
    func messages(inChat chatId: String, from: (orderKey: String, id: String), limit: Int) throws -> [MessageRecord] {
        try base.messages(inChat: chatId, from: from, limit: limit)
    }
    func messageCount(inChat chatId: String) throws -> Int { try base.messageCount(inChat: chatId) }
    func allMessages(after: (orderKey: String, id: String)?, limit: Int) throws -> [MessageRecord] {
        try base.allMessages(after: after, limit: limit)
    }
    func pendingSends(inChat chatId: String?, retryCeiling: Int16, limit: Int) throws -> [MessageRecord] {
        try base.pendingSends(inChat: chatId, retryCeiling: retryCeiling, limit: limit)
    }
    func ownMessages(in status: DeliveryStatus, limit: Int) throws -> [MessageRecord] {
        try base.ownMessages(in: status, limit: limit)
    }
    func changes() -> AsyncStream<Set<String>> { base.changes() }
    func insert(_ message: MessageRecord, searchText: String?) throws -> Bool { try base.insert(message, searchText: searchText) }
    func insert(_ messages: [(message: MessageRecord, searchText: String?)]) throws -> Set<String> { try base.insert(messages) }
    func edit(_ id: String, body: Data, searchText: String?, editedAt: Date) throws -> Bool {
        try base.edit(id, body: body, searchText: searchText, editedAt: editedAt)
    }
    func setBody(_ id: String, body: Data, searchText: String?) throws -> Bool { try base.setBody(id, body: body, searchText: searchText) }
    func setDeliveryStatus(_ id: String, _ status: DeliveryStatus) throws -> Bool { try base.setDeliveryStatus(id, status) }
    func applySessionArchive(_ id: String, maxRetries: Int16) throws -> DeliveryStatusTransition.ArchiveOutcome? {
        try base.applySessionArchive(id, maxRetries: maxRetries)
    }
    func setRetryCount(_ id: String, _ count: Int16) throws -> Bool { try base.setRetryCount(id, count) }
    func incrementRetryCount(_ id: String) throws -> Int16? { try base.incrementRetryCount(id) }
    func setOrderKey(_ id: String, _ orderKey: String) throws -> Bool { try base.setOrderKey(id, orderKey) }
    func setTranscript(_ id: String, text: String?, language: String?, generatedAt: Date?) throws -> Bool {
        try base.setTranscript(id, text: text, language: language, generatedAt: generatedAt)
    }
    func delete(_ ids: Set<String>) throws { try base.delete(ids) }
}
