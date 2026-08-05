//
//  ChatTranscriptWindowTests.swift
//  ConstructMessengerTests
//
//  "Иногда всё наполнение чата исчезает, словно отмоталось куда-то в пустоту" (TODO 34), finally
//  reproduced from the 2026-08-05 build-577 log:
//
//      FRC updated: 51 recent + 14 historic = 65 total
//      FRC updated: 52 recent + 13 historic = 65 total
//      FRC updated: 36 recent + 20 historic = 56 total     ← nine messages simply absent
//
//  `applyFRCSnapshot` built the historic half by filtering `viewModel.messages` — the list — so the
//  list was its own and only source of history. Anything the validity filter dropped had nowhere to
//  be re-read from, and `historic + fetched` was an unsorted concatenation resting on "everything
//  outside the FRC window is older than everything in it", which the FRC does not guarantee: its
//  `fetchLimit` is not re-applied on incremental updates, so `fetchedObjects` drifts (51/52/36
//  inside one second in that same log).
//
//  The transcript is now a function of one window, re-read from Core Data. These tests pin the
//  properties that makes true, against a store that is deliberately fed out of order.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class ChatTranscriptWindowTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeChat() -> Chat {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.unreadCount = 0
        return chat
    }

    @discardableResult
    private func makeMessage(
        in chat: Chat,
        at timestamp: Date,
        text: String,
        id: String = UUID().uuidString
    ) -> Message {
        let msg = Message(context: context)
        msg.id = id
        msg.fromUserId = "peer"
        msg.toUserId = "me"
        msg.contentType = .regular
        msg.timestamp = timestamp
        msg.isSentByMe = false
        msg.deliveryStatus = .delivered
        msg.retryCount = 0
        msg.chat = chat
        msg.applyStoredEncryption(plaintext: text, contactId: "peer")
        return msg
    }

    private func makeStore(for chat: Chat) -> (ChatMessageStore, ChatViewModel) {
        let store = ChatMessageStore(chat: chat, viewContext: context)
        let vm = ChatViewModel(chat: chat, context: context)
        store.setViewModel(vm)
        return (store, vm)
    }

    // MARK: - The transcript must be ordered, whatever order Core Data was written in

    /// Messages do not arrive in timestamp order — an offline-queued peer message is stored with
    /// its *original* timestamp long after newer local sends (the premise of
    /// `ChatPreviewOrderingTests`). The transcript must still read oldest-first.
    func testTranscriptIsOrderedByTimestampRegardlessOfInsertionOrder() throws {
        let chat = makeChat()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Written deliberately out of order.
        makeMessage(in: chat, at: base.addingTimeInterval(300), text: "third")
        makeMessage(in: chat, at: base, text: "first")
        makeMessage(in: chat, at: base.addingTimeInterval(600), text: "fourth")
        makeMessage(in: chat, at: base.addingTimeInterval(100), text: "second")
        try context.save()

        let (store, vm) = makeStore(for: chat)
        store.setup()

        XCTAssertEqual(
            vm.messages.map { $0.timestamp },
            [base, base.addingTimeInterval(100), base.addingTimeInterval(300), base.addingTimeInterval(600)],
            "the concatenation this replaces put whatever fell outside the FRC window at the front"
        )
    }

    /// Messages sent in one burst share a timestamp to the millisecond. Without a tie-break their
    /// relative order flips between fetches, which is a transcript that reshuffles itself while the
    /// user is looking at it. `(timestamp, id)` makes it stable.
    func testSameTimestampMessagesHaveAStableOrder() throws {
        let chat = makeChat()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        makeMessage(in: chat, at: at, text: "c", id: "id-c")
        makeMessage(in: chat, at: at, text: "a", id: "id-a")
        makeMessage(in: chat, at: at, text: "b", id: "id-b")
        try context.save()

        let (store, vm) = makeStore(for: chat)
        store.setup()
        let firstRead = vm.messages.map { $0.id }

        // A second derivation of the same window must agree with the first.
        store.loadMoreMessages(trigger: .user)   // no older messages: window unchanged
        let secondRead = vm.messages.map { $0.id }

        XCTAssertEqual(firstRead, ["id-a", "id-b", "id-c"])
        XCTAssertEqual(secondRead, firstRead, "the same window must derive the same order twice")
    }

    // MARK: - The transcript must not be able to lose messages

    /// The defect itself: the list was the only carrier of history, so it could only shrink. Now it
    /// is re-read, so a redundant re-derivation cannot drop anything.
    func testRederivingTheWindowNeverLosesMessages() throws {
        let chat = makeChat()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<25 {
            makeMessage(in: chat, at: base.addingTimeInterval(Double(i) * 60), text: "m\(i)")
        }
        try context.save()

        let (store, vm) = makeStore(for: chat)
        store.setup()
        let initial = vm.messages.map { $0.id }
        XCTAssertEqual(initial.count, 25)

        // Drive the snapshot path repeatedly — this is what a receipt storm does.
        for _ in 0..<5 { store.loadMoreMessages(trigger: .indicatorAppeared) }

        XCTAssertEqual(
            vm.messages.map { $0.id }, initial,
            "nine messages went missing this way on device; the window must be idempotent"
        )
    }

    /// Paging older must widen the window, not splice a batch into a list that is its own history.
    func testLoadingOlderWidensTheWindowAndKeepsEverything() throws {
        let chat = makeChat()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 45 messages: more than the 30-message initial page, less than two pages.
        for i in 0..<45 {
            makeMessage(in: chat, at: base.addingTimeInterval(Double(i) * 60), text: "m\(i)")
        }
        try context.save()

        let (store, vm) = makeStore(for: chat)
        store.setup()
        XCTAssertEqual(vm.messages.count, 30, "initial page")
        let newestBefore = vm.messages.last?.id

        store.loadMoreMessages(trigger: .user)

        XCTAssertEqual(vm.messages.count, 45, "the remaining 15 are admitted, none dropped")
        XCTAssertEqual(vm.messages.last?.id, newestBefore, "paging older must not disturb the tail")
        XCTAssertEqual(
            vm.messages.map { $0.timestamp }, vm.messages.map { $0.timestamp }.sorted(),
            "still ordered after widening"
        )
    }

    /// Duplicate ids in a `ForEach` render unpredictably — the most plausible reading of a chat
    /// that shows a scroll extent and no content. One fetch cannot produce them; the merge could,
    /// whenever the FRC window slid under it.
    func testWindowHasNoDuplicateIds() throws {
        let chat = makeChat()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<40 {
            makeMessage(in: chat, at: base.addingTimeInterval(Double(i) * 60), text: "m\(i)")
        }
        try context.save()

        let (store, vm) = makeStore(for: chat)
        store.setup()
        store.loadMoreMessages(trigger: .user)

        let ids = vm.messages.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "a duplicated id is a list SwiftUI cannot render")
    }

    // MARK: - Boundary

    /// A page boundary landing inside a group of messages that share a timestamp must admit the
    /// whole group — widening by timestamp rather than by object identity is what guarantees it.
    func testPageBoundaryDoesNotSplitASharedTimestamp() throws {
        let chat = makeChat()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 30 newest, then a burst of 5 sharing one instant just below the page boundary.
        let burstAt = base
        for i in 0..<5 { makeMessage(in: chat, at: burstAt, text: "burst\(i)") }
        for i in 0..<30 { makeMessage(in: chat, at: base.addingTimeInterval(Double(i + 1) * 60), text: "m\(i)") }
        try context.save()

        let (store, vm) = makeStore(for: chat)
        store.setup()
        store.loadMoreMessages(trigger: .user)

        let burstCount = vm.messages.filter { $0.timestamp == burstAt }.count
        XCTAssertEqual(burstCount, 5, "all five, or the boundary split a single instant across pages")
    }
}
