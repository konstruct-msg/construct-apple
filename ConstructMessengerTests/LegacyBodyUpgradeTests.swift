//
//  LegacyBodyUpgradeTests.swift
//  ConstructMessengerTests
//
//  Pre-CTM1 media bodies — JSON with a base64 media key — become the CTM1 body a row written
//  today holds, once, in the store; nothing else changes.
//

import XCTest
@testable import Construct_Messenger

final class LegacyBodyUpgradeTests: XCTestCase {

    private let key = Data((0..<32).map { UInt8($0) })
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Legacy bodies, as the builds before 2026-07-26 wrote them

    private func mediaJSON(hash: String = "a1b2c3", extra: [String: Any] = [:]) -> Data {
        var second: [String: Any] = [
            "mediaId": "m2", "mediaUrl": "https://x/m2", "mediaKey": key.base64EncodedString(),
            "mediaType": "video/mp4", "size": 2048, "hash": "0f0e", "duration": 3.5,
            "width": 480, "height": 640, "presentation": "video_note",
        ]
        second.merge(extra) { $1 }
        let obj: [String: Any] = [
            "type": "media", "caption": "look",
            "media": [
                ["mediaId": "m1", "mediaUrl": "https://x/m1", "mediaKey": key.base64EncodedString(),
                 "mediaType": "image/jpeg", "size": 1024, "hash": hash, "width": 800, "height": 600,
                 "blurhash": "LEHV6n"],
                second,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func voiceJSON() -> Data {
        try! JSONEncoder().encode(VoiceMessageContent(
            type: "voice", mediaId: "v1", mediaUrl: "https://x/v1", mediaKey: key, mediaType: "audio/m4a",
            size: 4096, duration: 2.2504, waveform: [0, 0.5, 1, 0.123], hash: "abcd"
        ))
    }

    private func fileJSON() -> Data {
        try! JSONEncoder().encode(FileMessageContent(type: "file", caption: "doc", files: [
            .init(mediaId: "f1", mediaUrl: "https://x/f1", mediaKey: key, mediaType: "application/pdf",
                  size: 9000, hash: "beef", filename: "a.pdf"),
        ]))
    }

    private func display(_ body: Data) -> String { LocalMessagePayload.decode(body).displayString }

    // MARK: - One body

    func testMediaJSONBecomesAnAlbumThatShowsTheSame() throws {
        let legacy = mediaJSON()
        let body = try XCTUnwrap(LegacyBodyUpgrade.converted(legacy))
        guard case .mediaAlbum = LocalMessagePayload.decode(body) else { return XCTFail("not a CTM1 album") }
        XCTAssertFalse(body.range(of: Data(key.base64EncodedString().utf8)) != nil, "the key is stored as bytes")
        let shown = try XCTUnwrap(parseMediaContent(from: display(body)))
        XCTAssertEqual(shown.caption, "look")
        XCTAssertEqual(shown.mediaItems.count, 2)
        XCTAssertEqual((shown.mediaItems[0]["mediaKey"] as? String).flatMap { Data(base64Encoded: $0) }, key)
        XCTAssertEqual(shown.mediaItems[0]["blurhash"] as? String, "LEHV6n")
        XCTAssertEqual(MediaPresentation.of(shown.mediaItems[1]), .videoNote)
        XCTAssertEqual(shown.mediaItems[1]["duration"] as? Double, 3.5)
    }

    func testVoiceJSONBecomesMessageContentThatShowsTheSame() throws {
        let body = try XCTUnwrap(LegacyBodyUpgrade.converted(voiceJSON()))
        guard case .messageContent = LocalMessagePayload.decode(body) else { return XCTFail("not CTM1 content") }
        let shown = try XCTUnwrap(parseVoiceContent(from: display(body)))
        XCTAssertEqual(shown.mediaKey, key)
        XCTAssertEqual(shown.mediaId, "v1")
        XCTAssertEqual(shown.duration, 2.25, accuracy: 0.001)
    }

    func testFileJSONBecomesAFileAlbumThatShowsTheSame() throws {
        let body = try XCTUnwrap(LegacyBodyUpgrade.converted(fileJSON()))
        let shown = try XCTUnwrap(MessageBubbleContentParsing.parseFileMessage(display(body)))
        XCTAssertEqual(shown.caption, "doc")
        XCTAssertEqual(shown.files.first?.mediaKey, key)
        XCTAssertEqual(shown.files.first?.filename, "a.pdf")
    }

    func testWhatHoldsNoMediaKeyIsLeftAlone() {
        XCTAssertNil(LegacyBodyUpgrade.converted(Data("{not json, just someone's text".utf8)))
        XCTAssertNil(LegacyBodyUpgrade.converted(Data("hello".utf8)))
        XCTAssertNil(LegacyBodyUpgrade.converted(LocalMessagePayload.encodeText("hello")))
        let placeholder = MessagePersistenceService.placeholderBody(caption: "", items: [])
        XCTAssertNil(LegacyBodyUpgrade.converted(Data(placeholder.utf8)))
        XCTAssertNil(LegacyBodyUpgrade.converted(Data(#"{"type":"voice","mediaId":"","mediaUrl":"","mediaKey":"","mediaType":"audio/m4a","size":0,"duration":1,"waveform":[],"hash":"","_uploading":true}"#.utf8)))
    }

    func testABodyThatWouldShowDifferentlyIsNotConverted() {
        // Not hex: the proto keeps the hash as bytes, so it would be lost.
        XCTAssertNil(LegacyBodyUpgrade.converted(mediaJSON(hash: "not-hex")))
        // An item with no key: nothing to carry, and a row like it is not one to guess about.
        XCTAssertNil(LegacyBodyUpgrade.converted(mediaJSON(extra: ["mediaKey": ""])))
    }

    // MARK: - The store

    func testThePassConvertsTheStoreOnceAndTouchesNothingElse() throws {
        let session = LocalStoreSession.inMemoryForTesting()
        let store = LocalRepositories.Backing.localStore(session)
        try store.contacts.insert(ContactRecord(
            id: "peer", username: "peer", displayName: "Peer", localAlias: nil, avatar: nil,
            knownIdentityKey: nil, accountAddress: nil, isContact: true, isBlocked: false,
            isSharingWithMe: false, amISharingWith: false, sharedWithMeAt: nil, addedAt: t0,
            ktStatus: .verified, securityNotice: .none, profileEditedAtMs: 0, pendingAvatarRef: nil,
            pendingAvatarSince: nil
        ))
        try store.chats.insert(ChatRecord(id: "chat", peerId: "peer", lastMessageText: nil, lastMessageTime: nil, isPinned: false, unreadCount: 0))
        func row(_ i: Int, _ body: Data) -> MessageRecord {
            MessageRecord(
                id: String(format: "00000000-0000-0000-0000-%012d", i), chatId: "chat", fromUserId: "peer",
                toUserId: "me", isSentByMe: false, timestamp: t0.addingTimeInterval(Double(i)),
                orderKey: String(format: "k%08d", i), body: body, contentType: .regular,
                deliveryStatus: .delivered, retryCount: 0, suiteId: 4, isEdited: false, editedAt: nil,
                replyToMessageId: nil, replyQuote: nil, transcript: nil, transcriptLanguage: nil,
                transcriptGeneratedAt: nil
            )
        }
        // Past one page, so the last rows are read on the second.
        let texts = (0..<LegacyBodyUpgrade.page).map { row($0, LocalMessagePayload.encodeText("t\($0)")) }
        let n = LegacyBodyUpgrade.page
        let legacyText = row(n, Data("plain old text".utf8))
        let kept = row(n + 1, mediaJSON(hash: "not-hex"))
        let media = row(n + 2, mediaJSON())
        let voice = row(n + 3, voiceJSON())
        let placeholder = row(n + 4, Data(MessagePersistenceService.placeholderBody(caption: "", items: []).utf8))
        try store.messages.insert((texts + [legacyText, kept, media, voice, placeholder]).map { ($0, nil) })

        let counts = try XCTUnwrap(LegacyBodyUpgrade.runIfDue(messages: store.messages, keyValue: store.keyValue))
        XCTAssertEqual(counts, .init(converted: 2, kept: 1))

        for converted in [media, voice] {
            let after = try XCTUnwrap(store.messages.message(converted.id))
            XCTAssertEqual(after.body, LegacyBodyUpgrade.converted(converted.body))
            XCTAssertFalse(after.isEdited, "a conversion is not an edit")
        }
        XCTAssertEqual(try store.messages.message(legacyText.id)?.body, legacyText.body)
        XCTAssertEqual(try store.messages.message(kept.id)?.body, kept.body)
        XCTAssertEqual(try store.messages.message(placeholder.id)?.body, placeholder.body)
        XCTAssertEqual(try store.messages.message(texts[7].id)?.body, texts[7].body)

        XCTAssertNotNil(try store.keyValue.get(LegacyBodyUpgrade.doneKey))
        try store.messages.setBody(media.id, body: media.body, searchText: nil)
        XCTAssertNil(try LegacyBodyUpgrade.runIfDue(messages: store.messages, keyValue: store.keyValue))
        XCTAssertEqual(try store.messages.message(media.id)?.body, media.body, "once only")
    }
}
