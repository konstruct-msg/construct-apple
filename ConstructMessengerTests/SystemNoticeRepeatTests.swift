//
//  SystemNoticeRepeatTests.swift
//  ConstructMessengerTests
//
//  A system notice must not restate a condition that has not changed.
//
//  Observed on both devices 2026-08-04: five identical "session out of sync" blocks stacked with
//  nothing between them. The 30 s cooldown on the caller was working — it bounds how often a new
//  notice may appear, and these were hours apart. What it cannot see is that nothing had happened
//  in between, so the fifth said exactly what the first did.
//
//  The rule under test: a notice is new information only if something reached the transcript since
//  the last identical one. A message arriving puts a different row last, which is the whole test.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
final class SystemNoticeRepeatTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var context: NSManagedObjectContext { container.viewContext }

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeChat() -> Chat {
        let other = User(context: context)
        other.id = UUID().uuidString
        other.username = "annie"
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = other
        try? context.save()
        return chat
    }

    @discardableResult
    private func addRow(
        _ text: String, from: String, to chat: Chat, at timestamp: Date
    ) -> Message {
        let m = Message(context: context)
        m.id = UUID().uuidString
        m.chat = chat
        m.fromUserId = from
        m.toUserId = "me"
        m.timestamp = timestamp
        m.isSentByMe = false
        m.deliveryStatus = .delivered
        m.applyStoredEncryption(plaintext: text, contactId: "annie")
        try? context.save()
        return m
    }

    private let notice = "The encrypted session is out of sync."

    /// The screenshot case: the same notice, nothing in between.
    func testIdenticalNoticeIsARepeatWhenItIsStillTheLastRow() {
        let chat = makeChat()
        addRow(notice, from: "SYSTEM", to: chat, at: Date())
        XCTAssertTrue(MessageRouter.isRepeatOfLastRowForTesting(notice, in: chat, context: context),
                      "five of these say what one says")
    }

    /// The case that must still get through: the session recovered enough to deliver something,
    /// then broke again. That second notice is real news.
    func testNoticeIsNotARepeatOnceAMessageArrives() {
        let chat = makeChat()
        addRow(notice, from: "SYSTEM", to: chat, at: Date().addingTimeInterval(-60))
        addRow("Привет", from: "annie", to: chat, at: Date())
        XCTAssertFalse(MessageRouter.isRepeatOfLastRowForTesting(notice, in: chat, context: context),
                       "a message got through in between — the state changed and saying so is informative")
    }

    /// A *different* notice is never suppressed: two conditions are two facts.
    func testDifferentNoticeIsNotARepeat() {
        let chat = makeChat()
        addRow(notice, from: "SYSTEM", to: chat, at: Date())
        XCTAssertFalse(
            MessageRouter.isRepeatOfLastRowForTesting("Contact changed their safety number.",
                                                     in: chat, context: context),
            "suppressing on 'is a system row' rather than on the text would silence unrelated notices"
        )
    }

    /// An empty chat has nothing to repeat.
    func testFirstNoticeInAnEmptyChatIsNeverARepeat() {
        XCTAssertFalse(MessageRouter.isRepeatOfLastRowForTesting(notice, in: makeChat(), context: context))
    }

    /// The last *row*, not the last system row: a peer message after the notice makes the next
    /// notice new, and ordering is by timestamp rather than insertion.
    func testOrderingIsByTimestampNotInsertion() {
        let chat = makeChat()
        addRow("Привет", from: "annie", to: chat, at: Date())              // newest
        addRow(notice, from: "SYSTEM", to: chat, at: Date().addingTimeInterval(-300))  // older
        XCTAssertFalse(MessageRouter.isRepeatOfLastRowForTesting(notice, in: chat, context: context),
                       "the newest row is the message, so the notice is not a repeat")
    }
}
