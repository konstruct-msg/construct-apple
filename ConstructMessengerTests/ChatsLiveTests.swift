//
//  ChatsLiveTests.swift
//  ConstructMessengerTests
//
//  What the chats lists read (chats C): the list follows every write, in the crate's order, the
//  badge sums the unread, and a search finds a chat by its person. Each test names the mutation
//  that must redden it.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class ChatsLiveTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var chats: CoreDataChatStore!
    private var live: ChatsLive!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        chats = CoreDataChatStore(container: container)
        live = ChatsLive(store: chats)
    }

    override func tearDown() {
        live = nil
        chats = nil
        container = nil
        super.tearDown()
    }

    private func contact(_ id: String, name: String = "") throws {
        try CoreDataContactStore(container: container).insert({
            var row = ContactRecord.new(id: id, isContact: true, addedAt: nil)
            row.displayName = name
            return row
        }())
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "not reached in 2 s", file: file, line: line)
    }

    /// A write moves the list: a new chat appears, a newer preview takes the top. Mutation: keep
    /// the list after a change (drop `list = nil` in `refresh`) — the screen never sees either.
    func testTheListFollowsEveryWrite() async throws {
        XCTAssertTrue(live.chats().isEmpty)
        try contact("a")
        try contact("b")
        let a = try chats.openChat(withPeer: "a", now: Date(timeIntervalSince1970: 100)).chat
        let b = try chats.openChat(withPeer: "b", now: Date(timeIntervalSince1970: 200)).chat
        await eventually { live.chats().map(\.id) == [b.id, a.id] }

        try chats.setPreview(a.id, text: "later", time: Date(timeIntervalSince1970: 300))
        await eventually { live.chats().map(\.id) == [a.id, b.id] }
        XCTAssertEqual(live.chat(a.id)?.lastMessageText, "later")
    }

    /// The badge is every chat's unread, summed. Mutation: count chats with unread instead.
    func testTheBadgeSumsTheUnread() async throws {
        try contact("a")
        try contact("b")
        let a = try chats.openChat(withPeer: "a").chat
        let b = try chats.openChat(withPeer: "b").chat
        try chats.setUnread(a.id, 3)
        try chats.setUnread(b.id, 2)
        await eventually { live.totalUnread == 5 }
    }

    /// A chat is found by its person's name, as the list shows it, or by its preview. Mutation:
    /// match the preview only — a search for the name finds nothing.
    func testASearchFindsAChatByItsPerson() throws {
        let record = ChatRecord(id: "c", peerId: "p", lastMessageText: "see you at nine",
                                lastMessageTime: nil, isPinned: false, unreadCount: 0)
        ContactsLive.useForPreview(container)
        defer { ContactsLive.useForPreview(PersistenceController.shared.container) }
        try contact("p", name: "Ada Lovelace")
        XCTAssertTrue(ChatsLive.matches(record, query: "lovelace"))
        XCTAssertTrue(ChatsLive.matches(record, query: "nine"))
        XCTAssertFalse(ChatsLive.matches(record, query: "babbage"))
    }

    /// A replaced store (sign-out, wipe) leaves no row behind. Mutation: ignore
    /// `.localStoreReplaced` — the old list stays on screen.
    func testAReplacedStoreLeavesNothingBehind() async throws {
        try contact("a")
        _ = try chats.openChat(withPeer: "a")
        // The insert's own announcement must have landed first, or it — not the replacement —
        // would empty the list below.
        await eventually { live.revision >= 1 && live.chats().count == 1 }
        // Rows gone underneath without a save this store would announce, as a wipe does.
        let context = container.newBackgroundContext()
        try context.performAndWait {
            let all = NSBatchDeleteRequest(fetchRequest: Chat.fetchRequest())
            try context.execute(all)
        }
        XCTAssertEqual(live.chats().count, 1, "a batch delete is not announced")
        NotificationCenter.default.post(name: .localStoreReplaced, object: nil)
        await eventually { live.chats().isEmpty }
    }

    /// Sign-out on macOS puts a new store under the running app, and the next account's chats are
    /// written there — by a history sync seconds later. The list reads them, and hears the writes.
    /// Mutation: keep the store the list was made with — the list stays empty (2026-10-22, a
    /// linked Mac after a sign-out showed no chats until relaunched).
    /// Mutation: keep listening to the old store's changes — the chat written after the
    /// replacement never appears.
    func testAfterAReplacementTheListReadsAndHearsTheNewStore() async throws {
        try contact("a")
        _ = try chats.openChat(withPeer: "a")
        var current: any ChatStore = chats
        let following = ChatsLive { current }
        await eventually { following.chats().count == 1 }

        let next = PersistenceController(inMemory: true).container
        let nextChats = CoreDataChatStore(container: next)
        current = nextChats
        NotificationCenter.default.post(name: .localStoreReplaced, object: nil)
        await eventually { following.chats().isEmpty }

        try CoreDataContactStore(container: next).insert(.new(id: "b", isContact: true, addedAt: nil))
        let b = try nextChats.openChat(withPeer: "b").chat
        await eventually { following.chats().map(\.id) == [b.id] }
    }
}
