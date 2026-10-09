//
//  ChatStoreTests.swift
//  ConstructMessengerTests
//
//  What any `ChatStore` must answer. Run against Core Data today; the `LocalStore` implementation
//  (LOCAL_STORE_MIGRATION_PLAN step 3) runs the same cases. Contacts are written through
//  `ContactStore`, as the app writes them; duplicate chats are seeded as Core Data, the one store
//  that can hold them.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class ChatStoreTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var store: CoreDataChatStore!
    private var contacts: CoreDataContactStore!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        store = CoreDataChatStore(container: container)
        contacts = CoreDataContactStore(container: container)
    }

    override func tearDown() {
        store = nil
        contacts = nil
        container = nil
        super.tearDown()
    }

    private func contact(_ id: String) throws {
        try contacts.insert(.new(id: id, isContact: true, addedAt: nil))
    }

    private func record(_ id: String, peer: String, time: Date? = nil, pinned: Bool = false) -> ChatRecord {
        ChatRecord(id: id, peerId: peer, lastMessageText: time.map { _ in "hi" }, lastMessageTime: time,
                   isPinned: pinned, unreadCount: 0)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "not reached in 2 s", file: file, line: line)
    }

    /// Every field the record carries comes from its column. Mutation: map one field from the
    /// wrong attribute in `ChatRecord(row:)` — the record reads back different.
    func testARowReadsBackWhole() throws {
        try contact("p")
        let at = Date(timeIntervalSince1970: 1_000)
        let written = ChatRecord(id: "c", peerId: "p", lastMessageText: "hello", lastMessageTime: at,
                                 isPinned: true, unreadCount: 3)
        XCTAssertTrue(try store.insert(written))
        XCTAssertEqual(try store.chat("c"), written)
        XCTAssertEqual(try store.chat(withPeer: "p"), written)
        XCTAssertNil(try store.chat("nothing"))
        XCTAssertNil(try store.chat(withPeer: "nobody"))
    }

    /// One chat per peer, and an id names one chat. Mutation: drop the peer check in `insert` —
    /// the second chat for "p" is added.
    func testAPeerHasOneChat() throws {
        try contact("p")
        try contact("q")
        XCTAssertTrue(try store.insert(record("c1", peer: "p")))
        XCTAssertFalse(try store.insert(record("c2", peer: "p")), "a second chat for the same peer")
        XCTAssertFalse(try store.insert(record("c1", peer: "q")), "a second chat under the same id")
        XCTAssertEqual(try store.chats().map(\.id), ["c1"])
    }

    /// The crate refuses a chat with no contact row (a foreign key); so does this one. Mutation:
    /// create the chat with no `otherUser` — it is added and then never read back.
    func testAChatNeedsItsContact() throws {
        XCTAssertThrowsError(try store.insert(record("c", peer: "stranger")))
        XCTAssertTrue(try store.chats().isEmpty)
    }

    /// Opening twice gives one chat; a new one, and an old one with no time, is stamped so it sits
    /// at the top of the list. Mutation: skip the stamp of an existing chat.
    func testOpeningIsFindOrAdd() throws {
        try contact("p")
        let now = Date(timeIntervalSince1970: 5_000)
        let first = try store.openChat(withPeer: "p", now: now)
        XCTAssertTrue(first.created)
        XCTAssertEqual(first.chat.lastMessageTime, now)
        let again = try store.openChat(withPeer: "p", now: now.addingTimeInterval(9))
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.chat.id, first.chat.id)
        XCTAssertEqual(again.chat.lastMessageTime, now, "a chat with a time keeps it")

        try contact("q")
        try store.insert(record("bare", peer: "q"))
        let stamped = try store.openChat(withPeer: "q", now: now)
        XCTAssertEqual(stamped.chat.lastMessageTime, now)
        XCTAssertEqual(try store.chat("bare")?.lastMessageTime, now)
    }

    /// Messages arrive out of order: the preview moves forward and on an equal time, never back.
    /// Mutation: compare with `<=` — the equal time is dropped; drop the comparison — an older
    /// message replaces the newer preview.
    func testThePreviewMovesOnlyForward() throws {
        try contact("p")
        let t = Date(timeIntervalSince1970: 100)
        try store.insert(record("c", peer: "p"))
        XCTAssertTrue(try store.advancePreview("c", text: "one", time: t))
        XCTAssertFalse(try store.advancePreview("c", text: "older", time: t.addingTimeInterval(-1)))
        XCTAssertEqual(try store.chat("c")?.lastMessageText, "one")
        XCTAssertTrue(try store.advancePreview("c", text: "same second", time: t))
        XCTAssertEqual(try store.chat("c")?.lastMessageText, "same second")
        XCTAssertTrue(try store.advancePreview("c", text: "newer", time: t.addingTimeInterval(1)))
        XCTAssertEqual(try store.chat("c")?.lastMessageTime, t.addingTimeInterval(1))

        // After a deletion it is set whatever it was, and cleared when nothing is left.
        XCTAssertTrue(try store.setPreview("c", text: "back", time: t.addingTimeInterval(-50)))
        XCTAssertEqual(try store.chat("c")?.lastMessageText, "back")
        XCTAssertTrue(try store.setPreview("c", text: nil, time: nil))
        XCTAssertNil(try store.chat("c")?.lastMessageTime)
    }

    /// Each write changes its fields and nothing else. Mutation: write a field outside the named
    /// set in any of them — the chat reads back different.
    func testEachWriteChangesOnlyItsFields() throws {
        try contact("p")
        let t = Date(timeIntervalSince1970: 100)
        var expected = record("c", peer: "p", time: t)
        try store.insert(expected)
        try store.incrementUnread("c"); try store.incrementUnread("c"); expected.unreadCount = 2
        XCTAssertEqual(try store.chat("c"), expected)
        try store.setPinned("c", true); expected.isPinned = true
        XCTAssertEqual(try store.chat("c"), expected)
        try store.setUnread("c", 0); expected.unreadCount = 0
        XCTAssertEqual(try store.chat("c"), expected)
    }

    /// Mutation: create the row in `update` when it is missing.
    func testAWriteToNoChatIsReportedAndCreatesNothing() throws {
        XCTAssertFalse(try store.incrementUnread("nothing"))
        XCTAssertFalse(try store.setPinned("nothing", true))
        XCTAssertFalse(try store.advancePreview("nothing", text: "x", time: Date()))
        XCTAssertTrue(try store.chats().isEmpty)
    }

    /// The crate's order: pinned first, then most recent, no message last, id between equals.
    /// Mutation: put chats with no time first — "empty" leads.
    func testTheListOrderIsTheCrates() throws {
        for p in ["a", "b", "c", "d", "e"] { try contact(p) }
        let t = Date(timeIntervalSince1970: 100)
        try store.insert(record("old", peer: "a", time: t))
        try store.insert(record("new", peer: "b", time: t.addingTimeInterval(10)))
        try store.insert(record("empty", peer: "c"))
        try store.insert(record("pinned", peer: "d", time: t, pinned: true))
        try store.insert(record("also-old", peer: "e", time: t))
        XCTAssertEqual(try store.chats().map(\.id), ["pinned", "new", "also-old", "old", "empty"])
    }

    /// Among duplicates Core Data still holds, the read names the chat the merge keeps. Mutation:
    /// return the first fetched — the read and a later `Chat.findOrCreate` disagree on the id.
    func testAmongDuplicatesTheReadNamesTheOneKept() throws {
        // Both insertion orders, so neither the first nor the last row fetched is the answer
        // by accident of the store's order.
        let orders = ["p": [("quiet", 10.0), ("busy", 20.0)], "q": [("busy", 20.0), ("quiet", 10.0)]]
        let context = container.viewContext
        for (peerId, rows) in orders {
            try contact(peerId)
            let peer = try User.row(peerId, in: context)
            for (name, seconds) in rows {
                let chat = Chat(context: context)
                chat.id = "\(peerId)-\(name)"
                chat.otherUser = peer
                chat.lastMessageTime = Date(timeIntervalSince1970: seconds)
                // One save each: a context's inserted objects are a set, and one save would
                // write them in no particular order.
                try context.save()
            }
        }
        for peerId in orders.keys {
            XCTAssertEqual(try store.chat(withPeer: peerId)?.id, "\(peerId)-busy")
            let merged = try XCTUnwrap(Chat.findOrCreate(forUserId: peerId, in: context))
            XCTAssertEqual(merged.chat.id, "\(peerId)-busy")
        }
    }

    /// The chat and its messages go; the contact stays. Mutation: delete the peer instead.
    func testDeletingAChatKeepsTheContact() throws {
        try contact("p")
        try store.insert(record("c", peer: "p"))
        let context = container.viewContext
        let message = PreviewHelpers.createSampleMessage(
            context: context, chat: try Chat.row("c", in: context), isSentByMe: false, text: "hi"
        )
        message.fromUserId = "p"
        message.toUserId = "me"
        try context.save()

        try store.delete("c")
        XCTAssertNil(try store.chat("c"))
        XCTAssertNotNil(try contacts.contact("p"))
        context.refreshAllObjects()
        XCTAssertEqual(try context.count(for: Message.fetchRequest()), 0)
    }

    /// A write through the store and a save elsewhere are both announced, by chat id. Mutation:
    /// return `nil` for a `Chat` in the feed's `rowId`.
    func testTheFeedAnnouncesEveryChatWrite() async throws {
        var seen = Set<String>()
        let changes = store.changes()
        let reading = Task { for await ids in changes { seen.formUnion(ids) } }
        defer { reading.cancel() }

        try contact("p")
        try store.insert(record("via-repo", peer: "p"))
        try store.incrementUnread("via-repo")
        await eventually { seen.contains("via-repo") }
        XCTAssertFalse(seen.contains("p"), "a contact's id is not a chat's")
    }
}
