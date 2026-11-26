import CoreData
import XCTest
@testable import Construct_Messenger

/// A call stands in its conversation (`CallTranscript`): a row that names the call log's record,
/// at the time the call started; a missed call is unread and the list says so.
final class CallTranscriptTests: XCTestCase {

    private var container: NSPersistentContainer!
    private var messages: CoreDataMessageStore!
    private var chats: CoreDataChatStore!
    private var calls: CoreDataCallStore!
    private let me = "00000000-0000-0000-0000-00000000000a"
    private let peer = "00000000-0000-0000-0000-00000000000b"
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
        messages = CoreDataMessageStore(container: container)
        chats = CoreDataChatStore(container: container)
        calls = CoreDataCallStore(container: container)
        try! CoreDataContactStore(container: container).insert(.new(id: peer, isContact: true, addedAt: nil))
        LocalRepositories.useCallsForTesting(calls)
    }

    override func tearDown() {
        LocalRepositories.useCallsForTesting(nil)
        messages = nil
        chats = nil
        calls = nil
        container = nil
        super.tearDown()
    }

    private func call(
        _ id: String = "C1", _ direction: CallRecord.Direction = .incoming,
        _ status: CallRecord.Status = .missed, seconds: Int32 = 0
    ) -> CallRecord {
        CallRecord(
            id: id, peerUserId: peer, peerName: "Anna", direction: direction, status: status,
            startedAt: started, endedAt: started.addingTimeInterval(Double(seconds) + 5),
            durationSeconds: seconds
        )
    }

    private func chat() throws -> ChatRecord { try XCTUnwrap(chats.chat(withPeer: peer)) }

    // MARK: - The row

    func testTheRowIdNamesTheCallAndBack() {
        XCTAssertEqual(CallTranscript.messageId(callId: "AbC"), "call-abc")
        XCTAssertEqual(CallTranscript.callId(ofMessage: "CALL-abc"), "abc")
        XCTAssertNil(CallTranscript.callId(ofMessage: "abc"), "an ordinary message names no call")
        XCTAssertNil(CallTranscript.callId(ofMessage: "call-"))
    }

    func testAnOutgoingCallIsOursAndAnIncomingOneTheirs() {
        let out = CallTranscript.row(for: call("C1", .outgoing, .completed), chatId: "chat", ownUserId: me)
        XCTAssertTrue(out.isSentByMe)
        XCTAssertEqual(out.fromUserId, me)
        XCTAssertEqual(out.toUserId, peer)

        let inc = CallTranscript.row(for: call(), chatId: "chat", ownUserId: me)
        XCTAssertFalse(inc.isSentByMe)
        XCTAssertEqual(inc.fromUserId, peer)
        XCTAssertEqual(inc.toUserId, me)
        XCTAssertEqual(inc.contentType, .call)
        XCTAssertTrue(inc.body.isEmpty, "the call's facts live in the log, not in the row")
    }

    func testTheRowStandsAtTheTimeTheCallStarted() {
        let row = CallTranscript.row(for: call(), chatId: "chat", ownUserId: me)
        XCTAssertEqual(row.timestamp, started)
        XCTAssertEqual(row.orderKey, ServerMessageOrder.local(timestamp: started, messageId: "call-c1"))
        XCTAssertFalse(ServerMessageOrder.isPending(row.orderKey), "a pending key would pin it to the bottom")
    }

    func testOnlyAMissedIncomingCallIsUnread() {
        XCTAssertTrue(CallTranscript.raisesUnread(call("C", .incoming, .missed)))
        XCTAssertFalse(CallTranscript.raisesUnread(call("C", .outgoing, .missed)))
        XCTAssertFalse(CallTranscript.raisesUnread(call("C", .incoming, .declined)))
        XCTAssertFalse(CallTranscript.raisesUnread(call("C", .incoming, .completed)))
        XCTAssertFalse(CallTranscript.raisesUnread(call("C", .incoming, .failed)))
    }

    func testEachOutcomeHasItsOwnWords() {
        let keys: [(CallRecord.Direction, CallRecord.Status, String)] = [
            (.incoming, .missed, "call_row_missed"),
            (.outgoing, .missed, "call_row_unanswered"),
            (.incoming, .declined, "call_row_declined"),
            (.outgoing, .declined, "call_row_declined"),
            (.incoming, .failed, "call_row_failed"),
            (.outgoing, .failed, "call_row_failed"),
            (.incoming, .completed, "call_row_incoming"),
            (.outgoing, .completed, "call_row_outgoing"),
        ]
        for (direction, status, key) in keys {
            XCTAssertEqual(CallTranscript.labelKey(for: call("C", direction, status)), key, "\(direction) \(status)")
            XCTAssertNotEqual(NSLocalizedString(key, comment: ""), key, "\(key) has no English text")
        }
    }

    func testTheSummaryCarriesTheLengthOfACallThatTookPlace() {
        let answered = call("C", .outgoing, .completed, seconds: 185)
        XCTAssertEqual(CallTranscript.summary(for: answered), "\(CallTranscript.label(for: answered)) · 3:05")
        let missed = call("C", .incoming, .missed, seconds: 185)
        XCTAssertEqual(CallTranscript.summary(for: missed), CallTranscript.label(for: missed))
    }

    // MARK: - Writing it

    func testAMissedCallIsUnreadAndTheListSaysSo() throws {
        let missed = call()
        XCTAssertTrue(try CallTranscript.write(missed, announce: true, ownUserId: me, messages: messages, chats: chats))
        XCTAssertNotNil(try messages.message("call-c1"))
        let chat = try chat()
        XCTAssertEqual(chat.unreadCount, 1)
        XCTAssertEqual(chat.lastMessageText, Chat.formatPreviewText(CallTranscript.label(for: missed)))
        XCTAssertEqual(chat.lastMessageTime, started)
    }

    func testAnAnsweredCallIsInTheListButNotUnread() throws {
        try CallTranscript.write(call("C1", .incoming, .completed, seconds: 60), announce: true, ownUserId: me,
                                 messages: messages, chats: chats)
        let chat = try chat()
        XCTAssertEqual(chat.unreadCount, 0)
        XCTAssertNotNil(chat.lastMessageText)
    }

    func testAnImportedCallIsNotAnnounced() throws {
        try CallTranscript.write(call(), announce: false, ownUserId: me, messages: messages, chats: chats)
        XCTAssertNotNil(try messages.message("call-c1"), "the row is written")
        let chat = try chat()
        XCTAssertEqual(chat.unreadCount, 0, "an old missed call is not news")
        XCTAssertNil(chat.lastMessageText)
    }

    func testTheSameCallIsWrittenOnce() throws {
        XCTAssertTrue(try CallTranscript.write(call(), announce: true, ownUserId: me, messages: messages, chats: chats))
        XCTAssertFalse(try CallTranscript.write(call(), announce: true, ownUserId: me, messages: messages, chats: chats))
        XCTAssertEqual(try chat().unreadCount, 1, "a second write of one call counts nothing")
    }

    // MARK: - Shown, and gone with its call

    @MainActor func testACallRowIsShownAndIsTheChatsLatestLine() throws {
        let missed = call()
        try calls.upsert(missed)
        try CallTranscript.write(missed, announce: false, ownUserId: me, messages: messages, chats: chats)
        let row = try XCTUnwrap(messages.message("call-c1"))
        XCTAssertTrue(row.isListed)
        XCTAssertEqual(TranscriptWindow.visible([row]).map(\.id), ["call-c1"])

        XCTAssertTrue(MessagePersistenceService.reconcilePreview(ofChat: try chat(), store: messages, chats: chats))
        XCTAssertEqual(try chat().lastMessageText, Chat.formatPreviewText(CallTranscript.label(for: missed)))
    }

    func testDeletingACallTakesItsRowOutOfTheChat() throws {
        let missed = call()
        try calls.upsert(missed)
        try CallTranscript.write(missed, announce: true, ownUserId: me, messages: messages, chats: chats)
        try calls.delete(missed.id)
        CallHistoryService.deleteRows(of: [missed], messages: messages, chats: chats)
        XCTAssertNil(try messages.message("call-c1"))
        XCTAssertNil(try chat().lastMessageText, "the preview no longer names a call that is gone")
    }

    func testTheLogAnswersOneCallById() throws {
        try calls.upsert(call("C1"))
        try calls.upsert(call("C2", .outgoing, .completed))
        XCTAssertEqual(try calls.call("c2")?.direction, .outgoing)
        XCTAssertNil(try calls.call("C3"))
    }
}
