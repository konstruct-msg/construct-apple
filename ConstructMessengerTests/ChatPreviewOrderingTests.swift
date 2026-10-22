import XCTest
import CoreData
@testable import Construct_Messenger

/// The chat-list preview is the transcript's last message, in the transcript's order.
///
/// Messages do not arrive in timestamp order, and their timestamps are the sender's clock. The
/// preview first followed whichever message was written last (a late-delivered older one
/// clobbered it), then — until 2026-10-20 — the newest by timestamp, which kept a message the
/// server placed later out of the list: ours sent through a drop and acknowledged after the
/// peer's reply, or the peer's delivered after a reconnect. Now it is the transcript's order.
@MainActor
final class ChatPreviewOrderingTests: XCTestCase {
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        let container = PersistenceController(inMemory: true).container
        context = container.viewContext
        // The reconciler writes through `ChatStore` (chats B2); point it at this store.
        LocalRepositories.useChatsForTesting(container)
        LocalRepositories.useMessagesForTesting(container)
    }

    override func tearDown() {
        LocalRepositories.useChatsForTesting(nil)
        LocalRepositories.useMessagesForTesting(nil)
        context = nil
        super.tearDown()
    }

    /// A chat the repository can find: saved, with its peer's row.
    private func makeSavedChat() throws -> Chat {
        let peer = User(context: context)
        peer.id = "peer-" + UUID().uuidString
        peer.username = ""
        peer.displayName = ""
        let chat = makeChat()
        chat.otherUser = peer
        try context.save()
        return chat
    }

    private func stored(_ chat: Chat) throws -> ChatRecord {
        try XCTUnwrap(LocalRepositories.chats.chat(chat.id))
    }

    private func makeChat() -> Chat {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.unreadCount = 0
        return chat
    }

    func testFirstMessageSetsPreviewFromEmptyChat() {
        let chat = makeChat()
        XCTAssertNil(chat.lastMessageTime)

        let at = Date()
        chat.applyPreview(text: "hello", timestamp: at)

        XCTAssertEqual(chat.lastMessageText, "hello")
        XCTAssertEqual(chat.lastMessageTime, at)
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
    func testReconcilePreview_AdvancesStaleStampFromTranscript() throws {
        let chat = try makeSavedChat()
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
        try context.save()

        XCTAssertTrue(chat.reconcilePreviewFromTranscript())
        XCTAssertEqual(try stored(chat).lastMessageText, "По прежнему никаких обновлений")
        XCTAssertEqual(try stored(chat).lastMessageTime, newer)
    }

    func testReconcilePreview_NoOpWhenAlreadyInSync() throws {
        let chat = try makeSavedChat()
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
        try context.save()

        XCTAssertFalse(chat.reconcilePreviewFromTranscript())
        XCTAssertEqual(try stored(chat).lastMessageText, "hello")
    }

    func testReconcilePreview_UnfreezesFutureStamp() throws {
        let chat = try makeSavedChat()
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

        try context.save()

        XCTAssertTrue(chat.reconcilePreviewFromTranscript())
        XCTAssertEqual(try stored(chat).lastMessageText, "real tip")
        XCTAssertEqual(try stored(chat).lastMessageTime, real)
    }
}

// MARK: - Remote timestamp clamping
//
// Remote timestamps are skew- and sender-controlled, so they are clamped at ingestion: a time in
// the future is shown as now. (It once also froze the preview, while the preview went by time.)
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
}

// MARK: - The transcript's order decides

extension ChatPreviewOrderingTests {
    private func write(
        _ text: String, in chat: Chat, sentByMe: Bool, at seconds: TimeInterval, orderKey: String,
        id: String = UUID().uuidString.lowercased()
    ) throws -> String {
        try LocalRepositories.messages.insert(MessageRecord(
            id: id, chatId: chat.id, fromUserId: sentByMe ? "me" : "peer", toUserId: sentByMe ? "peer" : "me",
            isSentByMe: sentByMe, timestamp: Date(timeIntervalSince1970: seconds), orderKey: orderKey,
            body: Data(text.utf8), contentType: .regular, deliveryStatus: sentByMe ? .sending : .delivered,
            retryCount: 0, suiteId: 0, isEdited: false, editedAt: nil, replyToMessageId: nil,
            replyQuote: nil, transcript: nil, transcriptLanguage: nil, transcriptGeneratedAt: nil
        ), searchText: text)
        MessagePersistenceService.refreshPreview(ofChat: chat.id)
        return id
    }

    private func serverKey(_ ms: Int64, _ seq: UInt64) throws -> String {
        try XCTUnwrap(ServerMessageOrder.key(serverTimestampMilliseconds: ms, sequence: seq))
    }

    /// The peer's message, written on a clock behind ours, is placed after our last one: it is
    /// the transcript's last, so it is the preview. Mutation: refresh by the message's own time
    /// (the rule before 2026-10-20) — "mine" stays.
    func testAMessagePlacedLaterIsThePreviewWhateverItsClockSays() throws {
        let chat = try makeSavedChat()
        _ = try write("mine", in: chat, sentByMe: true, at: 1_000, orderKey: serverKey(2_000_000, 1))
        XCTAssertEqual(try stored(chat).lastMessageText, "mine")

        _ = try write("theirs", in: chat, sentByMe: false, at: 900, orderKey: serverKey(2_000_500, 2))
        XCTAssertEqual(try stored(chat).lastMessageText, "theirs")
    }

    /// Ours, sent through a drop: pending, it is last; the peer's reply arrives meanwhile; the
    /// acknowledgement then places ours before the reply, and the reply becomes the preview.
    /// Mutation: drop the refresh in `updateServerOrder` — "mine" stays.
    func testAnAcknowledgementThatPlacesOursEarlierHandsThePreviewToTheReply() throws {
        let chat = try makeSavedChat()
        let mine = try write("mine", in: chat, sentByMe: true, at: 1_000,
                             orderKey: ServerMessageOrder.pending(localMessageId: "m1", composedAt: Date(timeIntervalSince1970: 0)), id: "m1")
        _ = try write("theirs", in: chat, sentByMe: false, at: 1_005, orderKey: serverKey(2_000_500, 2))
        XCTAssertEqual(try stored(chat).lastMessageText, "mine", "a pending message sits last")

        MessagePersistenceService().updateServerOrder(
            messageId: mine, serverOrderKey: try serverKey(2_000_000, 1), in: context
        )
        XCTAssertEqual(try stored(chat).lastMessageText, "theirs")
    }
}
