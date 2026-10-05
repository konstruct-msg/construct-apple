//
//  MessageReadableTextTests.swift
//  ConstructMessengerTests
//
//  What a person reads of a message (`readableText`) and what may be sent again as text
//  (`plainText`), for every shape the store holds. Both exist because the body the bubble parsers
//  read — media, voice and files as legacy JSON — reached the screen and the wire under the name
//  `displayText`: the edit banner, copy, quote and search showed `{"caption":…,"media":[…]}`, and
//  a resend after a decryption error would have sent it as a text message.
//  Each test names the mutation that reddens it.
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class MessageReadableTextTests: XCTestCase {

    private func album(caption: String?, mime: String = "image/jpeg") -> Shared_Proto_Messaging_V1_MediaAlbumMessage {
        var item = Shared_Proto_Messaging_V1_MediaMessage()
        item.mediaID = "573686c0"
        item.mimeType = mime
        item.mediaType = .image
        item.fileURL = "https://example.invalid/m"
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = [item]
        if let caption { album.caption = caption }
        return album
    }

    private func decoded(_ data: Data) -> LocalMessagePayload { LocalMessagePayload.decode(data) }

    // MARK: - Media

    /// Mutation: `readableText` returns `displayString` — the edit banner of a captioned photo
    /// shows its JSON (2026-10-05).
    func testAPhotoReadsAsItsCaption() {
        let payload = decoded(LocalMessagePayload.encodeMediaAlbum(album(caption: "Осень во всю")))
        XCTAssertTrue(payload.displayString.hasPrefix("{"), "the parsers still get their JSON")
        XCTAssertEqual(payload.readableText, "Осень во всю")
    }

    func testAPhotoWithoutCaptionReadsAsNothing() {
        let payload = decoded(LocalMessagePayload.encodeMediaAlbum(album(caption: nil)))
        XCTAssertEqual(payload.readableText, "")
    }

    func testAMediaMessageContentReadsAsItsCaption() {
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.mediaAlbum = album(caption: "подпись")
        XCTAssertEqual(decoded(LocalMessagePayload.encodeMessageContent(content)).readableText, "подпись")
    }

    /// A row stored before CTM1 is the legacy JSON itself.
    func testALegacyMediaRowReadsAsItsCaption() throws {
        let json = try XCTUnwrap(MediaWireCodec.mediaJSON(from: album(caption: "старое")))
        let payload = LocalMessagePayload.legacyUTF8(Data(json.utf8))
        XCTAssertEqual(payload.readableText, "старое")
        XCTAssertNil(payload.plainText)
    }

    /// Mutation: drop the media branch in `previewHint`'s legacy case — an old photo's chat-list
    /// line is JSON.
    func testALegacyMediaRowPreviewsAsWords() throws {
        let captioned = try XCTUnwrap(MediaWireCodec.mediaJSON(from: album(caption: "старое")))
        XCTAssertEqual(LocalMessagePayload.legacyUTF8(Data(captioned.utf8)).previewHint, "старое")
        let bare = try XCTUnwrap(MediaWireCodec.mediaJSON(from: album(caption: nil)))
        XCTAssertFalse(LocalMessagePayload.legacyUTF8(Data(bare.utf8)).previewHint.hasPrefix("{"))
    }

    func testVoiceReadsAsNothing() {
        var voice = Shared_Proto_Messaging_V1_VoiceMessage()
        voice.fileURL = "https://example.invalid/v"
        voice.durationMs = 1000
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.voice = voice
        let payload = decoded(LocalMessagePayload.encodeMessageContent(content))
        XCTAssertEqual(payload.readableText, "")
        XCTAssertNil(payload.plainText)
    }

    // MARK: - Text

    func testTextIsItself() {
        let payload = decoded(LocalMessagePayload.encodeText("привет"))
        XCTAssertEqual(payload.readableText, "привет")
        XCTAssertEqual(payload.plainText, "привет")
    }

    /// Mutation: treat every body starting with `{` as JSON — a person who types braces loses
    /// their message from search, copy and the bubble.
    func testTextThatLooksLikeJSONIsStillText() {
        let typed = #"{"hello": 1}"#
        let payload = LocalMessagePayload.legacyUTF8(Data(typed.utf8))
        XCTAssertEqual(payload.readableText, typed)
        XCTAssertEqual(payload.plainText, typed)
    }

    // MARK: - Resend

    /// Mutation: `plainText` returns `displayString` for media — a resend after a decryption error
    /// sends the peer a text message of JSON.
    func testOnlyATextMessageCanBeResentAsText() {
        XCTAssertNil(decoded(LocalMessagePayload.encodeMediaAlbum(album(caption: "x"))).plainText)
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.mediaAlbum = album(caption: "x")
        XCTAssertNil(decoded(LocalMessagePayload.encodeMessageContent(content)).plainText)
    }
}
