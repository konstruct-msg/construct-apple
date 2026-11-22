//
//  MessageMediaIndexTests.swift
//  ConstructMessengerTests
//
//  The store's media index, as this app fills it (construct-docs todo 327): which media a body
//  holds (`MessageMediaIndex`), written with every message, and filled once for what an older
//  build wrote. Each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class MessageMediaIndexTests: XCTestCase {

    private typealias Item = Shared_Proto_Messaging_V1_MediaMessage

    private func item(_ id: String, mime: String, size: UInt64 = 10,
                      presentation: Shared_Proto_Messaging_V1_MediaPresentation = .unspecified) -> Item {
        var m = Item()
        m.mediaID = id
        m.mimeType = mime
        m.fileSize = size
        m.presentation = presentation
        return m
    }

    private func album(_ items: [Item]) -> Shared_Proto_Messaging_V1_MediaAlbumMessage {
        var a = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        a.items = items
        return a
    }

    private func content(_ fill: (inout Shared_Proto_Messaging_V1_MessageContent) -> Void) -> Data {
        var c = Shared_Proto_Messaging_V1_MessageContent()
        fill(&c)
        return LocalMessagePayload.storagePayload(forWireContent: c)
    }

    private func voiceBody(mediaId: String, size: Int) -> Data {
        content { c in
            var v = Shared_Proto_Messaging_V1_VoiceMessage()
            v.codec = "audio/m4a|\(mediaId)|\(size)"
            c.voice = v
        }
    }

    private func summary(_ entries: [LocalMediaEntry]?) -> [String]? {
        entries?.map { "\($0.item):\($0.mediaId):\($0.kind):\($0.byteSize)" }
    }

    // MARK: What a body holds

    /// Each item by its own kind, at its own position; one with no id is left out and the rest keep
    /// their positions. Mutations: a round video read as a video, a GIF as a photo, a PDF as a
    /// photo, or positions counted after the gap — each reddens.
    func testAnAlbumIsIndexedItemByItemInItsOwnPositions() {
        let body = LocalMessagePayload.encodeMediaAlbum(album([
            item("p", mime: "image/jpeg", size: 1),
            item("", mime: "image/jpeg"),
            item("v", mime: "video/mp4", size: 3),
            item("n", mime: "video/mp4", size: 4, presentation: .videoNote),
            item("g", mime: "image/gif", size: 5),
            item("d", mime: "application/pdf", size: 6),
        ]))
        XCTAssertEqual(summary(MessageMediaIndex.entries(for: body)), [
            "0:p:photo:1", "2:v:video:3", "3:n:videoNote:4", "4:g:animation:5", "5:d:file:6",
        ])
    }

    /// What arrives — and all Android writes — is a message content: an album, one media, or a
    /// voice note, whose id rides in `codec`. A text or a sticker is indexed empty, so the backfill
    /// stops listing it. Mutations: drop the content album, the single media, or the voice case;
    /// return nil for a content text — each reddens.
    func testAMessageContentIsIndexedByWhatItHolds() {
        let albumBody = content { $0.mediaAlbum = album([item("a", mime: "image/png", size: 7)]) }
        XCTAssertEqual(summary(MessageMediaIndex.entries(for: albumBody)), ["0:a:photo:7"])

        let single = content { $0.media = item("s", mime: "video/quicktime", size: 8) }
        XCTAssertEqual(summary(MessageMediaIndex.entries(for: single)), ["0:s:video:8"])

        XCTAssertEqual(summary(MessageMediaIndex.entries(for: voiceBody(mediaId: "vn", size: 42))), ["0:vn:voice:42"])

        let text = content { c in
            var t = Shared_Proto_Messaging_V1_TextMessage()
            t.text = "hi"
            c.text = t
        }
        XCTAssertEqual(summary(MessageMediaIndex.entries(for: text)), [])
        let sticker = content { $0.sticker = Shared_Proto_Messaging_V1_StickerRef() }
        XCTAssertEqual(summary(MessageMediaIndex.entries(for: sticker)), [])
    }

    /// A plain text, a profile or a pre-CTM1 row is not asked about. Mutation: return `[]` for them
    /// — every text written would add an index row.
    func testATextOrAnOlderBodyIsNotAskedAbout() {
        XCTAssertNil(MessageMediaIndex.entries(for: LocalMessagePayload.encodeText("hello")))
        XCTAssertNil(MessageMediaIndex.entries(for: LocalMessagePayload.encodeProfileBinary(Data([1]))))
        XCTAssertNil(MessageMediaIndex.entries(for: Data("{\"type\":\"media\"}".utf8)))
    }

    // MARK: Written with the message

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

    private func record(_ id: String, key: String, body: Data) -> MessageRecord {
        MessageRecord(
            id: id, chatId: chatId, fromUserId: "peer", toUserId: "me", isSentByMe: false,
            timestamp: Date(timeIntervalSince1970: 1_000), orderKey: key, body: body,
            contentType: .regular, deliveryStatus: .delivered, retryCount: 0, suiteId: 4,
            isEdited: false, editedAt: nil, replyToMessageId: nil, replyQuote: nil, transcript: nil,
            transcriptLanguage: nil, transcriptGeneratedAt: nil
        )
    }

    private func galleryIds() throws -> [String] {
        try session.store.chatMedia(
            chatId: chatId, kinds: [], beforeOrderKey: nil, beforeMessageId: nil, beforeItem: nil, limit: 50
        ).map(\.mediaId)
    }

    /// A message written one at a time or in a batch is in the chat's media at once; a body
    /// replaced by a text clears what it indexed, and an edit indexes its new body. Mutations: drop
    /// the index in `insert`, in the batch `insert`, or in `edit`, or the clearing in `setBody` —
    /// each reddens.
    func testWritingAMessageIndexesItsMedia() throws {
        let photo = LocalMessagePayload.encodeMediaAlbum(album([item("p1", mime: "image/jpeg")]))
        XCTAssertTrue(try messages.insert(record("m1", key: "k1", body: photo), searchText: nil))
        XCTAssertEqual(try galleryIds(), ["p1"])

        let added = try messages.insert([
            (record("m2", key: "k2", body: voiceBody(mediaId: "v2", size: 1)), nil),
            (record("m3", key: "k3", body: LocalMessagePayload.encodeText("hi")), "hi"),
        ])
        XCTAssertEqual(added, ["m2", "m3"])
        XCTAssertEqual(try galleryIds(), ["v2", "p1"])

        XCTAssertTrue(try messages.setBody("m1", body: LocalMessagePayload.encodeText("gone"), searchText: "gone"))
        XCTAssertEqual(try galleryIds(), ["v2"])

        let edited = LocalMessagePayload.encodeMediaAlbum(album([item("e3", mime: "image/png")]))
        XCTAssertTrue(try messages.edit("m3", body: edited, searchText: nil, editedAt: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(try galleryIds(), ["e3", "v2"])
    }

    /// What an older build wrote — straight into the store, no index — is indexed by the backfill,
    /// and a second run finds nothing to do. Mutations: stop after the first page, or index the
    /// listed rows as empty — each reddens.
    func testTheBackfillIndexesWhatAnOlderBuildWrote() throws {
        let old = [
            record("o1", key: "k1", body: LocalMessagePayload.encodeMediaAlbum(album([item("a1", mime: "image/heic")]))),
            record("o2", key: "k2", body: content { $0.media = item("a2", mime: "video/mp4") }),
            record("o3", key: "k3", body: voiceBody(mediaId: "a3", size: 3)),
        ]
        for row in old {
            XCTAssertEqual(try session.store.insertMessage(message: row.local, searchText: nil), .inserted)
        }
        XCTAssertEqual(try galleryIds(), [])

        XCTAssertEqual(try messages.indexUnindexedMedia(pageSize: 2), 3)
        XCTAssertEqual(try galleryIds(), ["a3", "a2", "a1"])
        XCTAssertEqual(try messages.indexUnindexedMedia(pageSize: 2), 0)
    }
}
