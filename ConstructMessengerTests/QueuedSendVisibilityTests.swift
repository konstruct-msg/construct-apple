//
//  QueuedSendVisibilityTests.swift
//  ConstructMessengerTests
//
//  A send held for a session must be on screen while it waits.
//
//  `ChatSendCoordinator.sendMessage` used to append to an in-memory queue and return without
//  writing anything: the composer cleared, and the chat stayed blank until the session came up
//  (real send) or gave up (`failQueuedMessages` inserted a `.failed` row). During a slow session
//  init that is a visible hole and the same complaint as the invisible upload placeholder fixed in
//  sessions/2026-07-31-send-feedback-invisible-upload-placeholder — "I sent it and nothing
//  happened". Media suffered more: its branch returned before `sendMediaMessage`, so not even an
//  upload placeholder was created.
//
//  Two things this pins that are easy to regress in opposite directions:
//    1. queueing writes exactly ONE row (writing none is the original defect);
//    2. giving up FLIPS that row (inserting a second was correct only while queueing wrote none —
//       now it shows the same message twice, once waiting forever and once failed).
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class QueuedSendVisibilityTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }
    private let me = "8f2c1d55-0000-4000-8000-000000000001"
    private var peer = ""

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeCoordinator() -> (ChatSendCoordinator, Chat) {
        let other = User(context: context)
        other.id = UUID().uuidString
        other.username = "annie"
        peer = other.id
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = other
        try? context.save()

        let coordinator = ChatSendCoordinator(
            chat: chat,
            viewContext: context,
            sessionManager: ChatSessionManager(chat: chat)
        )
        return (coordinator, chat)
    }

    private func rows(in chat: Chat) -> [Message] {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "chat == %@", chat)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - The hole

    /// The defect itself: queueing a text send left the transcript empty.
    func testQueuedTextSendIsVisibleImmediately() {
        let (coordinator, chat) = makeCoordinator()
        XCTAssertTrue(rows(in: chat).isEmpty)

        coordinator.enqueueUntilSessionExistsForTesting(
            text: "погоди, сейчас", recipientId: peer, currentUserId: me)

        let written = rows(in: chat)
        XCTAssertEqual(written.count, 1, "the send must be on screen while it waits for a session")
        XCTAssertEqual(written.first?.deliveryStatus, .queued)
        XCTAssertEqual(written.first?.displayText, "погоди, сейчас")
        XCTAssertEqual(written.first?.isSentByMe, true)
    }

    /// `.queued` is not decoration: `MessageRetryManager.sendQueuedMessages` fetches exactly that
    /// status, which is what drains the row. A stub written as `.sending` or `.failed` would sit
    /// on screen and never be sent by anyone.
    func testQueuedTextSendIsInTheStateTheFlushFetches() {
        let (coordinator, chat) = makeCoordinator()
        coordinator.enqueueUntilSessionExistsForTesting(
            text: "hi", recipientId: peer, currentUserId: me)

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(
            format: "chat == %@ AND deliveryStatusRaw == %d", chat, DeliveryStatus.queued.rawValue)
        XCTAssertEqual((try? context.fetch(request))?.count, 1,
                       "the row must match the predicate the queued flush uses, or nothing drains it")
    }

    /// Media queued before a session gets a placeholder too — its branch used to return before
    /// `sendMediaMessage`, so not even the upload cell appeared.
    func testQueuedMediaSendGetsAPlaceholderRow() {
        let (coordinator, chat) = makeCoordinator()
        coordinator.enqueueUntilSessionExistsForTesting(
            text: "подпись",
            fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")],
            recipientId: peer, currentUserId: me)

        XCTAssertEqual(rows(in: chat).count, 1, "a queued file send must show its upload cell")
    }

    // MARK: - Give-up must not duplicate

    /// The regression the fix makes possible: the row already exists, so failing must flip it.
    func testGiveUpFlipsTheExistingRowInsteadOfAddingASecond() {
        let (coordinator, chat) = makeCoordinator()
        coordinator.enqueueUntilSessionExistsForTesting(
            text: "не дошло", recipientId: peer, currentUserId: me)
        let queuedId = rows(in: chat).first?.id

        coordinator.failQueuedMessagesForTesting(reason: "init_failed")

        let after = rows(in: chat)
        XCTAssertEqual(after.count, 1, "the same message must not appear twice — once stuck, once failed")
        XCTAssertEqual(after.first?.id, queuedId, "the row on screen is the one that must fail")
        XCTAssertEqual(after.first?.deliveryStatus, .failed)
    }

    /// A queued media send must fail its placeholder, not leave it uploading forever.
    func testGiveUpFailsTheMediaPlaceholder() {
        let (coordinator, chat) = makeCoordinator()
        coordinator.enqueueUntilSessionExistsForTesting(
            text: "фото", fileURLs: [URL(fileURLWithPath: "/tmp/a.jpg")],
            recipientId: peer, currentUserId: me)

        coordinator.failQueuedMessagesForTesting(reason: "init_failed")

        let after = rows(in: chat)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.deliveryStatus, .failed,
                       "a placeholder left at .sending is stuck: no sweeper resets that state")
    }

    /// Failing twice must stay idempotent — the give-up callback is not guaranteed to fire once.
    func testGiveUpTwiceDoesNotDuplicate() {
        let (coordinator, chat) = makeCoordinator()
        coordinator.enqueueUntilSessionExistsForTesting(
            text: "once", recipientId: peer, currentUserId: me)

        coordinator.failQueuedMessagesForTesting(reason: "init_failed")
        coordinator.failQueuedMessagesForTesting(reason: "init_failed")

        XCTAssertEqual(rows(in: chat).count, 1)
    }

    /// Text must not be held in memory as well as in Core Data. Both drains are live at once —
    /// `onSessionReady` replays the in-memory queue while `connectionStatus == .connected` runs the
    /// Core Data flush — so a text send in both places is delivered to the peer TWICE.
    ///
    /// Row counting alone cannot see this (a send in both places still leaves one row, and the
    /// duplicate only appears on the success path a unit test cannot reach), so the in-memory queue
    /// is asserted directly. An earlier version of this test checked only the row count and passed
    /// under the mutation it was written to catch.
    func testTextIsNotAlsoHeldInTheInMemoryQueue() {
        let (coordinator, chat) = makeCoordinator()
        coordinator.enqueueUntilSessionExistsForTesting(
            text: "single", recipientId: peer, currentUserId: me)

        XCTAssertEqual(coordinator.inMemoryQueueCountForTesting, 0,
                       "text belongs to the Core Data queue only — held in both, the peer gets it twice")
        XCTAssertEqual(rows(in: chat).count, 1)
        XCTAssertEqual(rows(in: chat).first?.displayText, "single")
    }

    /// The converse: media MUST be in memory, because the Core Data flush cannot carry it
    /// (`reencryptAndSend` refuses `.media`, and there is no content to re-encrypt until the
    /// upload produces it). Its row is a placeholder for visibility, not a queue entry.
    func testMediaIsHeldInMemoryBecauseTheFlushCannotCarryIt() {
        let (coordinator, _) = makeCoordinator()
        coordinator.enqueueUntilSessionExistsForTesting(
            text: "фото", fileURLs: [URL(fileURLWithPath: "/tmp/a.jpg")],
            recipientId: peer, currentUserId: me)

        XCTAssertEqual(coordinator.inMemoryQueueCountForTesting, 1,
                       "nothing else would ever send this — the queued flush skips media")
    }
}
