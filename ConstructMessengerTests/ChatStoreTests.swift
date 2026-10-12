//
//  ChatStoreTests.swift
//  ConstructMessengerTests
//
//  What any `ChatStore` must answer, run on both implementations — Core Data here, `LocalStore` in
//  the subclass below (LOCAL_STORE_MIGRATION_PLAN step 3). Contacts are written through
//  `ContactStore`, as the app writes them. Duplicate chats — which only Core Data can hold — and
//  the message cascade through its relationships are `CoreDataChatStoreTests`.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
class ChatStoreTests: XCTestCase {

    /// A chat store and a contact store over one database.
    func makeStores() -> (chats: any ChatStore, contacts: any ContactStore) {
        let container = PersistenceController(inMemory: true).container
        return (CoreDataChatStore(container: container), CoreDataContactStore(container: container))
    }

    private var store: (any ChatStore)!
    private var contacts: (any ContactStore)!

    override func setUp() {
        super.setUp()
        (store, contacts) = makeStores()
    }

    override func tearDown() {
        store = nil
        contacts = nil
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

    /// A chat a message is about to be written into is opened with no time: the message's own,
    /// older than now, must still move the preview. Mutation: stamp `now` when it is nil (or
    /// default it) — the received message's time is refused.
    func testAChatOpenedForAMessageTakesNoTime() throws {
        try contact("p")
        let opened = try store.openChat(withPeer: "p", now: nil)
        XCTAssertTrue(opened.created)
        XCTAssertNil(try store.chat(opened.chat.id)?.lastMessageTime)
        let sent = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(try store.advancePreview(opened.chat.id, text: "hi", time: sent))
        XCTAssertEqual(try store.chat(opened.chat.id)?.lastMessageTime, sent)
    }

    /// Two first messages from one person, on two threads, open one chat, and both openings
    /// succeed. Without the lock Core Data adds no second chat either — the later save fails on
    /// the conflict over the peer's `chats` — but an opening that throws is a received message
    /// left unwritten, sent again by the server. Rounds, each with a new peer, because one race
    /// can be won by order alone. Mutation: drop the lock around `CoreDataChatStore.insert` —
    /// an opening throws.
    func testOpeningsAtOnceGiveOneChat() throws {
        let peers = (0..<20).map { "peer-\($0)" }
        for peer in peers { try contact(peer) }
        let store = self.store!
        for peer in peers {
            let lock = NSLock()
            var opened: [Result<String, Error>] = []
            DispatchQueue.concurrentPerform(iterations: 6) { _ in
                let result = Result { try store.openChat(withPeer: peer, now: nil).chat.id }
                lock.lock(); opened.append(result); lock.unlock()
            }
            let ids = try opened.map { try $0.get() }
            XCTAssertEqual(Set(ids).count, 1, peer)
        }
        let byPeer = Dictionary(grouping: try store.chats(), by: \.peerId)
        for peer in peers {
            XCTAssertEqual(byPeer[peer]?.count, 1, peer)
        }
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

    /// The chat goes; the contact stays. Mutation: delete the peer instead.
    func testDeletingAChatKeepsTheContact() throws {
        try contact("p")
        try store.insert(record("c", peer: "p"))
        try store.delete("c")
        XCTAssertNil(try store.chat("c"))
        XCTAssertNil(try store.chat(withPeer: "p"))
        XCTAssertNotNil(try contacts.contact("p"))
        XCTAssertNoThrow(try store.delete("c"), "a second delete finds nothing and says nothing")
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

/// The same cases on the crate.
final class LocalStoreChatStoreTests: ChatStoreTests {
    override func makeStores() -> (chats: any ChatStore, contacts: any ContactStore) {
        let session = LocalStoreSession.inMemoryForTesting()
        return (LocalStoreChatStore(session: session), LocalStoreContactStore(session: session))
    }
}

/// What only Core Data has: duplicate chats for one peer, which the crate's unique index cannot
/// hold, and the message cascade through its relationships (the crate's is `delete_chat`, tested
/// there).
@MainActor
final class CoreDataChatStoreTests: XCTestCase {

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

    /// Among duplicates Core Data still holds, the read names the chat the launch merge keeps,
    /// and the merge leaves that one. Mutation: return the first fetched in `best(forPeer:)` —
    /// the read and the merge disagree on the id.
    func testAmongDuplicatesTheReadNamesTheOneKept() throws {
        // Both insertion orders, so neither the first nor the last row fetched is the answer
        // by accident of the store's order.
        let orders = ["p": [("quiet", 10.0), ("busy", 20.0)], "q": [("busy", 20.0), ("quiet", 10.0)]]
        for (peerId, rows) in orders {
            for (name, seconds) in rows {
                try duplicate("\(peerId)-\(name)", of: peerId, at: seconds)
            }
        }
        for peerId in orders.keys {
            XCTAssertEqual(try store.chat(withPeer: peerId)?.id, "\(peerId)-busy")
        }
        XCTAssertEqual(DuplicateChats.merge(in: container.viewContext), 2)
        XCTAssertEqual(try store.chats().map(\.id).sorted(), ["p-busy", "q-busy"])
    }

    /// The merge loses nothing: the messages move, the unread counts add up, the newest preview
    /// and a pin survive. Mutation: skip any one of those in `DuplicateChats.merge` — this reddens.
    func testTheLaunchMergeKeepsEverything() throws {
        try duplicate("kept", of: "p", at: 20, unread: 2)
        try duplicate("gone", of: "p", at: 10, unread: 3, pinned: true)
        let context = container.viewContext
        var messageIds: [String] = []
        for chat in ["kept", "gone"] {
            let message = PreviewHelpers.createSampleMessage(
                context: context, chat: try Chat.row(chat, in: context), isSentByMe: false, text: chat
            )
            message.fromUserId = "p"
            message.toUserId = "me"
            messageIds.append(message.id)
        }
        try context.save()

        XCTAssertEqual(DuplicateChats.merge(in: context), 1)
        let kept = try XCTUnwrap(store.chat("kept"))
        XCTAssertNil(try store.chat("gone"))
        XCTAssertEqual(kept.unreadCount, 5)
        XCTAssertTrue(kept.isPinned)
        XCTAssertEqual(kept.lastMessageTime, Date(timeIntervalSince1970: 20))
        let messages = CoreDataMessageStore(container: container)
        for id in messageIds {
            XCTAssertEqual(try messages.message(id)?.chatId, "kept")
        }
        XCTAssertEqual(DuplicateChats.merge(in: context), 0, "nothing left to merge")
    }

    /// A chat row beside the one the store holds for the peer — what builds before 2026-10-12
    /// could leave. One save each: a context's inserted objects are a set, and one save would
    /// write them in no particular order.
    private func duplicate(_ id: String, of peerId: String, at seconds: TimeInterval,
                           unread: Int16 = 0, pinned: Bool = false) throws {
        let context = container.viewContext
        if try contacts.contact(peerId) == nil { try contact(peerId) }
        let chat = Chat(context: context)
        chat.id = id
        chat.otherUser = try User.row(peerId, in: context)
        chat.lastMessageTime = Date(timeIntervalSince1970: seconds)
        chat.lastMessageText = id
        chat.unreadCount = unread
        chat.isPinned = pinned
        try context.save()
    }

    /// The chat's messages go with it. Mutation: `messages` set to nullify — the message stays.
    func testDeletingAChatTakesItsMessages() throws {
        try contact("p")
        try store.insert(ChatRecord(id: "c", peerId: "p", lastMessageText: nil, lastMessageTime: nil,
                                    isPinned: false, unreadCount: 0))
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
}
