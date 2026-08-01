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

    /// List self-heal: when denormalized preview lags the transcript (missed writer /
    /// frozen stamp), `reconcilePreviewFromTranscript` force-aligns to the newest message.
    func testReconcilePreview_AdvancesStaleStampFromTranscript() {
        let chat = makeChat()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(3_600)

        chat.applyPreview(text: "Ложное сообщение о доставке", timestamp: older)

        let msg = Message(context: context)
        msg.id = UUID().uuidString
        msg.fromUserId = "peer"
        msg.toUserId = "me"
        msg.contentType = .regular
        msg.timestamp = newer
        msg.isSentByMe = true
        msg.deliveryStatus = .sent
        msg.retryCount = 0
        msg.chat = chat
        msg.applyStoredEncryption(plaintext: "По прежнему никаких обновлений", contactId: "peer")

        XCTAssertTrue(chat.reconcilePreviewFromTranscript(in: context))
        XCTAssertEqual(chat.lastMessageText, "По прежнему никаких обновлений")
        XCTAssertEqual(chat.lastMessageTime, newer)
    }

    func testReconcilePreview_NoOpWhenAlreadyInSync() {
        let chat = makeChat()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        chat.applyPreview(text: "hello", timestamp: at)

        let msg = Message(context: context)
        msg.id = UUID().uuidString
        msg.fromUserId = "peer"
        msg.toUserId = "me"
        msg.contentType = .regular
        msg.timestamp = at
        msg.isSentByMe = false
        msg.deliveryStatus = .delivered
        msg.retryCount = 0
        msg.chat = chat
        msg.applyStoredEncryption(plaintext: "hello", contactId: "peer")

        XCTAssertFalse(chat.reconcilePreviewFromTranscript(in: context))
        XCTAssertEqual(chat.lastMessageText, "hello")
    }

    func testReconcilePreview_UnfreezesFutureStamp() {
        let chat = makeChat()
        let real = Date(timeIntervalSince1970: 1_700_000_000)
        let frozen = real.addingTimeInterval(3 * 3600)

        chat.applyPreview(text: "frozen future", timestamp: frozen)

        let msg = Message(context: context)
        msg.id = UUID().uuidString
        msg.fromUserId = "peer"
        msg.toUserId = "me"
        msg.contentType = .regular
        msg.timestamp = real
        msg.isSentByMe = false
        msg.deliveryStatus = .delivered
        msg.retryCount = 0
        msg.chat = chat
        msg.applyStoredEncryption(plaintext: "real tip", contactId: "peer")

        // Without reconcile, applyPreview would refuse a later real message older than freeze.
        chat.applyPreview(text: "would be refused", timestamp: real.addingTimeInterval(1))
        XCTAssertEqual(chat.lastMessageText, "frozen future")

        XCTAssertTrue(chat.reconcilePreviewFromTranscript(in: context))
        XCTAssertEqual(chat.lastMessageText, "real tip")
        XCTAssertEqual(chat.lastMessageTime, real)
    }
}

// MARK: - Remote timestamp clamping
//
// The ordering guard above has a sharp edge: a timestamp in the FUTURE freezes the row
// permanently, because every later message — local or remote — is then "older" and refused.
// Before the guard existed this was self-correcting (the next writer simply overwrote it), so
// the guard converted a transient wrong preview into a permanent one. Remote timestamps are
// skew- and sender-controlled, so they are clamped at ingestion.
extension ChatPreviewOrderingTests {

    func testRemoteTimestampInTheFutureIsClampedToNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threeHoursAhead = UInt64(now.addingTimeInterval(3 * 3600).timeIntervalSince1970)

        let clamped = Date.fromRemoteTimestamp(threeHoursAhead, now: now)

        XCTAssertEqual(clamped, now, "A message cannot have been sent after we received it")
    }

    func testRemoteTimestampInThePastIsLeftAlone() {
        // Legitimate: anything that sat in the server's offline queue keeps its original time.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)

        let clamped = Date.fromRemoteTimestamp(UInt64(twoDaysAgo.timeIntervalSince1970), now: now)

        XCTAssertEqual(clamped.timeIntervalSince1970, twoDaysAgo.timeIntervalSince1970, accuracy: 1)
    }

    func testClampingKeepsLaterMessagesAbleToAdvanceThePreview() {
        // The end-to-end property that was broken: a peer with a fast clock must not be able
        // to freeze the row against every subsequent message.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = makeChat()

        let skewed = Date.fromRemoteTimestamp(
            UInt64(now.addingTimeInterval(3 * 3600).timeIntervalSince1970),
            now: now
        )
        chat.applyPreview(text: "from a peer whose clock is ahead", timestamp: skewed)

        // A local send one second later must still win.
        chat.applyPreview(text: "my newer reply", timestamp: now.addingTimeInterval(1))

        XCTAssertEqual(chat.lastMessageText, "my newer reply")
    }

    func testUnclampedFutureTimestampWouldFreezeTheRow() {
        // Pins the exact failure the clamp exists to prevent — if this ever passes with the
        // newer text, the ordering guard has been weakened rather than the clamp fixed.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = makeChat()

        chat.applyPreview(text: "future", timestamp: now.addingTimeInterval(3 * 3600))
        chat.applyPreview(text: "my newer reply", timestamp: now.addingTimeInterval(1))

        XCTAssertEqual(chat.lastMessageText, "future", "guard still refuses to move backwards")
    }
}
