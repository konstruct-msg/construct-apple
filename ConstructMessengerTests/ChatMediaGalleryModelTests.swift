//
//  ChatMediaGalleryModelTests.swift
//  ConstructMessengerTests
//
//  The chat gallery's model (construct-docs todo 327): which tab shows what, how it pages, and the
//  file list's one row per message. On the real store, so the index is the one writes fill. Each
//  test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ChatMediaGalleryModelTests: XCTestCase {

    private var session: LocalStoreSession!
    private var messages: LocalStoreMessageStore!
    private var chatId = ""

    override func setUp() async throws {
        try await super.setUp()
        session = LocalStoreSession.inMemoryForTesting()
        messages = LocalStoreMessageStore(session: session)
        try LocalStoreContactStore(session: session).insert(.new(id: "peer", isContact: true, addedAt: nil))
        chatId = try LocalStoreChatStore(session: session).openChat(withPeer: "peer").chat.id
    }

    override func tearDown() async throws {
        messages = nil
        session = nil
        try await super.tearDown()
    }

    private func item(_ id: String, mime: String, videoNote: Bool = false) -> Shared_Proto_Messaging_V1_MediaMessage {
        var m = Shared_Proto_Messaging_V1_MediaMessage()
        m.mediaID = id
        m.mimeType = mime
        if videoNote { m.presentation = .videoNote }
        return m
    }

    /// A message `id` at `second`, its body an album of `items`.
    private func write(_ id: String, at second: Int, _ items: [Shared_Proto_Messaging_V1_MediaMessage]) throws {
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = items
        try messages.insert(MessageRecord(
            id: id, chatId: chatId, fromUserId: "peer", toUserId: "me", isSentByMe: false,
            timestamp: Date(timeIntervalSince1970: TimeInterval(second)),
            orderKey: String(format: "k%04d", second), body: LocalMessagePayload.encodeMediaAlbum(album),
            contentType: .regular, deliveryStatus: .delivered, retryCount: 0, suiteId: 4, isEdited: false,
            editedAt: nil, replyToMessageId: nil, replyQuote: nil, transcript: nil, transcriptLanguage: nil,
            transcriptGeneratedAt: nil
        ), searchText: nil)
    }

    private func model(_ tab: ChatMediaTab = .visual, pageSize: Int = 90) -> ChatMediaGalleryModel {
        ChatMediaGalleryModel(chatId: chatId, tab: tab, store: messages, pageSize: pageSize)
    }

    /// Pictures, videos and animations in the grid; files in the list; voice notes and round
    /// videos in neither. Mutations: the grid asks for files, or the list for voice notes — each
    /// reddens.
    func testEachTabShowsItsOwnKinds() throws {
        try write("m1", at: 1, [item("p", mime: "image/jpeg"), item("v", mime: "video/mp4"), item("g", mime: "image/gif")])
        try write("m2", at: 2, [item("d", mime: "application/pdf")])
        try write("m3", at: 3, [item("n", mime: "video/mp4", videoNote: true)])
        var voice = Shared_Proto_Messaging_V1_VoiceMessage()
        voice.codec = "audio/m4a|a|1"
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.voice = voice
        try messages.insert(MessageRecord(
            id: "m4", chatId: chatId, fromUserId: "peer", toUserId: "me", isSentByMe: false,
            timestamp: Date(timeIntervalSince1970: 4), orderKey: "k0004",
            body: LocalMessagePayload.storagePayload(forWireContent: content), contentType: .regular,
            deliveryStatus: .delivered, retryCount: 0, suiteId: 4, isEdited: false, editedAt: nil,
            replyToMessageId: nil, replyQuote: nil, transcript: nil, transcriptLanguage: nil,
            transcriptGeneratedAt: nil
        ), searchText: nil)

        let grid = model(.visual)
        grid.loadMore()
        XCTAssertEqual(grid.items.map(\.mediaId), ["g", "v", "p"])

        let list = model(.files)
        list.loadMore()
        XCTAssertEqual(list.items.map(\.mediaId), ["d"])
    }

    /// Page after page from where the last stopped, until one comes back short; nothing is read
    /// twice and nothing after the end. Mutations: page from the start each time, or call a full
    /// page the end — each reddens.
    func testPagesContinueUntilAShortOne() throws {
        for second in 1...5 { try write("m\(second)", at: second, [item("p\(second)", mime: "image/png")]) }
        let gallery = model(pageSize: 2)

        gallery.loadMore()
        gallery.loadMore()
        XCTAssertEqual(gallery.items.map(\.mediaId), ["p5", "p4", "p3", "p2"])
        XCTAssertFalse(gallery.isComplete)
        gallery.loadMore()
        XCTAssertEqual(gallery.items.map(\.mediaId), ["p5", "p4", "p3", "p2", "p1"])
        XCTAssertTrue(gallery.isComplete)
        gallery.loadMore()
        XCTAssertEqual(gallery.items.count, 5)
    }

    /// The next page is read once the grid nears the end of what it holds, not before.
    /// Mutation: the distance check reversed — the first tile would read on, the last not.
    func testTheNextPageIsReadNearTheEnd() throws {
        for second in 1...40 { try write("m\(second)", at: second, [item("p\(second)", mime: "image/png")]) }
        let gallery = model(pageSize: 20)
        gallery.loadMore()

        gallery.loadMoreIfNeeded(after: gallery.items[0])
        XCTAssertEqual(gallery.items.count, 20)
        gallery.loadMoreIfNeeded(after: gallery.items[20 - ChatMediaGalleryModel.prefetchDistance])
        XCTAssertEqual(gallery.items.count, 40)
    }

    /// A message of two files is one row of the list, the newest message first; the viewer pages
    /// the other way. Mutations: drop the de-duplication, or the reversal — each reddens.
    func testFilesAreOneRowPerMessage() throws {
        try write("m1", at: 1, [item("d1", mime: "application/pdf"), item("d2", mime: "application/zip")])
        try write("m2", at: 2, [item("d3", mime: "text/plain")])
        let list = model(.files)
        list.loadMore()

        XCTAssertEqual(list.items.count, 3)
        XCTAssertEqual(list.messageIds, ["m2", "m1"])
        XCTAssertEqual(list.rowsOldestFirst.map(\.id), ["m1", "m2"])
    }

    /// Another tab drops what was loaded and reads its own first page; the same tab again is not a
    /// reload. Mutation: keep the old items on a switch — the list holds pictures.
    func testSwitchingTabsStartsOver() throws {
        try write("m1", at: 1, [item("p", mime: "image/jpeg")])
        try write("m2", at: 2, [item("d", mime: "application/pdf")])
        let gallery = model(.visual)
        gallery.loadMore()
        XCTAssertEqual(gallery.items.map(\.mediaId), ["p"])

        gallery.select(.files)
        XCTAssertEqual(gallery.tab, .files)
        XCTAssertEqual(gallery.items.map(\.mediaId), ["d"])
        gallery.select(.files)
        XCTAssertEqual(gallery.items.map(\.mediaId), ["d"])
    }
}
