import XCTest
import CoreData
@testable import Construct_Messenger

/// Regression cover for the chat-list preview freezing on an older message.
///
/// Messages do not arrive in timestamp order: a peer message held in the server's offline
/// queue is stored with its *original* timestamp long after newer local sends, and background
/// fetch commits whole batches at once. Preview writers used to assign
/// `lastMessageText`/`lastMessageTime` directly, so one late-delivered older message clobbered
/// the row — the list showed the peer's stale text while the transcript ended with much newer
/// outgoing messages.
@MainActor
final class ChatPreviewOrderingTests: XCTestCase {
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    private func makeChat() -> Chat {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.unreadCount = 0
        return chat
    }

    /// The bug as observed on device: outgoing message at 16:53, then a peer message
    /// timestamped 15:29 lands late. The row must keep showing the newer outgoing one.
    func testLateDeliveredOlderMessageDoesNotClobberPreview() {
        let chat = makeChat()
        let sentAt = Date()

        chat.applyPreview(text: "Фигня какая", timestamp: sentAt)
        XCTAssertEqual(chat.lastMessageText, "Фигня какая")

        chat.applyPreview(text: "Проверка связи снова.", timestamp: sentAt.addingTimeInterval(-5000))

        XCTAssertEqual(chat.lastMessageText, "Фигня какая")
        XCTAssertEqual(chat.lastMessageTime, sentAt)
    }

    func testNewerMessageAdvancesPreview() {
        let chat = makeChat()
        let base = Date()

        chat.applyPreview(text: "older", timestamp: base)
        chat.applyPreview(text: "newer", timestamp: base.addingTimeInterval(60))

        XCTAssertEqual(chat.lastMessageText, "newer")
        XCTAssertEqual(chat.lastMessageTime, base.addingTimeInterval(60))
    }

    /// Outgoing timestamps are truncated to whole seconds (`UInt64(timeIntervalSince1970)`),
    /// so a strict `>` comparison silently dropped a message sent in the same second as the
    /// current preview. Equal timestamps must still update.
    func testSameSecondMessageStillUpdatesPreview() {
        let chat = makeChat()
        let sameInstant = Date(timeIntervalSince1970: 1_785_000_000)

        chat.applyPreview(text: "first", timestamp: sameInstant)
        chat.applyPreview(text: "second", timestamp: sameInstant)

        XCTAssertEqual(chat.lastMessageText, "second")
    }

    func testFirstMessageSetsPreviewFromEmptyChat() {
        let chat = makeChat()
        XCTAssertNil(chat.lastMessageTime)

        let at = Date()
        chat.applyPreview(text: "hello", timestamp: at)

        XCTAssertEqual(chat.lastMessageText, "hello")
        XCTAssertEqual(chat.lastMessageTime, at)
    }

    /// Deletion recomputes the preview from the surviving messages, which legitimately moves
    /// it backwards — the only caller allowed to bypass the ordering check.
    func testForcedPreviewMovesBackwardsAfterDeletion() {
        let chat = makeChat()
        let newest = Date()

        chat.applyPreview(text: "newest", timestamp: newest)
        chat.applyPreview(text: "survivor", timestamp: newest.addingTimeInterval(-600), force: true)

        XCTAssertEqual(chat.lastMessageText, "survivor")
        XCTAssertEqual(chat.lastMessageTime, newest.addingTimeInterval(-600))
    }

    func testClearPreviewEmptiesBothFields() {
        let chat = makeChat()
        chat.applyPreview(text: "something", timestamp: Date())

        chat.clearPreview()

        XCTAssertNil(chat.lastMessageText)
        XCTAssertNil(chat.lastMessageTime)
    }

    /// Control-signal payloads must never surface as preview text, and going through
    /// `applyPreview` must not lose that filtering.
    func testPreviewStillFiltersControlSignals() {
        let chat = makeChat()
        chat.applyPreview(text: "__session_ping", timestamp: Date())

        XCTAssertEqual(chat.lastMessageText, "")
    }
}
