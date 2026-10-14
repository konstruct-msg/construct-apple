//
//  VideoNotePresentationTests.swift
//  ConstructMessengerTests
//
//  A video note is a video with `MediaMessage.presentation = VIDEO_NOTE`
//  (`decisions/video-notes-are-uncropped-and-expand.md`). These pin that the mark survives every
//  hop this app makes it take — onto the wire, back into the local JSON the bubble reads, and
//  through a caption edit — and that a value this build does not know reads as the ordinary
//  bubble, which is what the field promises an older client does.
//

import XCTest
import SwiftProtobuf
@testable import Construct_Messenger

final class VideoNotePresentationTests: XCTestCase {

    private func item(_ presentation: MediaPresentation?) -> MediaMessageData {
        MediaMessageData(
            mediaId: "m1", mediaUrl: "u1", mediaKey: Data(repeating: 1, count: 32),
            mediaType: "video/mp4", size: 4096, width: 720, height: 960, duration: 4,
            thumbnail: nil, hash: "00ff", filename: nil, blurhash: nil,
            presentation: presentation
        )
    }

    private func localItem(_ content: Shared_Proto_Messaging_V1_MessageContent) throws -> [String: Any] {
        let json = try XCTUnwrap(MediaWireCodec.mediaJSON(from: content.mediaAlbum))
        return try XCTUnwrap(parseMediaContent(from: json)).media
    }

    func testVideoNoteGoesOnTheWireAndComesBack() throws {
        let content = MediaWireCodec.albumContent(mediaList: [item(.videoNote)], caption: "", quoted: nil)
        XCTAssertEqual(content.mediaAlbum.items.first?.presentation, .videoNote)

        // Through the bytes, as a receiver gets it.
        let decoded = try Shared_Proto_Messaging_V1_MessageContent(serializedBytes: content.serializedData())
        XCTAssertEqual(MediaPresentation.of(try localItem(decoded)), .videoNote)
    }

    func testAnOrdinaryVideoCarriesNoPresentation() throws {
        let content = MediaWireCodec.albumContent(mediaList: [item(nil)], caption: "", quoted: nil)
        XCTAssertEqual(content.mediaAlbum.items.first?.presentation, .unspecified)
        XCTAssertNil(MediaPresentation.of(try localItem(content)))
    }

    /// A caption edit rebuilds the album from local JSON; the mark must not fall out there.
    func testCaptionEditKeepsTheMark() throws {
        let content = MediaWireCodec.albumContent(mediaList: [item(.videoNote)], caption: "", quoted: nil)
        let json = try XCTUnwrap(MediaWireCodec.mediaJSON(from: content.mediaAlbum))
        let edited = try XCTUnwrap(MediaWireCodec.editedCaption(localJSON: json, newCaption: "hi"))
        XCTAssertEqual(edited.wire.mediaAlbum.items.first?.presentation, .videoNote)
        XCTAssertEqual(MediaPresentation.of(try XCTUnwrap(parseMediaContent(from: edited.localJSON)).media), .videoNote)
    }

    /// A presentation added after this build arrives as an unknown enum value; it is shown as
    /// what the item is.
    func testAnUnknownPresentationReadsAsTheOrdinaryBubble() throws {
        var m = Shared_Proto_Messaging_V1_MediaMessage()
        m.mimeType = "video/mp4"
        m.presentation = .UNRECOGNIZED(7)
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = [m]
        let json = try XCTUnwrap(MediaWireCodec.mediaJSON(from: album))
        XCTAssertNil(MediaPresentation.of(try XCTUnwrap(parseMediaContent(from: json)).media))
        XCTAssertNil(MediaPresentation.of(["presentation": "something_new"]))
    }

    /// The local JSON written by `MediaMessageData`'s own encoding uses the same key and value.
    func testCodableEncodingMatchesTheLocalJSONKey() throws {
        let data = try JSONEncoder().encode(item(.videoNote))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(MediaPresentation.of(dict), .videoNote)
        // Encoded before the field existed: still decodes.
        var old = dict
        old.removeValue(forKey: MediaPresentation.jsonKey)
        let decoded = try JSONDecoder().decode(
            MediaMessageData.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.presentation)
    }

    // MARK: Names in the chat list and in replies

    private func storedAlbum(_ presentation: MediaPresentation?, mime: String = "video/mp4") -> LocalMessagePayload {
        var data = item(presentation)
        if mime != "video/mp4" {
            data = MediaMessageData(mediaId: "m1", mediaUrl: "u1", mediaKey: Data(repeating: 1, count: 32),
                                    mediaType: mime, size: 4096, width: 1, height: 1, duration: nil,
                                    thumbnail: nil, hash: "00", filename: nil)
        }
        let album = MediaWireCodec.albumContent(mediaList: [data], caption: "", quoted: nil).mediaAlbum
        return LocalMessagePayload.decode(LocalMessagePayload.encodeMediaAlbum(album))
    }

    func testChatListNamesTheKindOfMedia() {
        XCTAssertEqual(storedAlbum(.videoNote).previewHint, NSLocalizedString("video_note", comment: ""))
        XCTAssertEqual(storedAlbum(nil).previewHint, NSLocalizedString("video", comment: ""))
        XCTAssertEqual(storedAlbum(nil, mime: "image/jpeg").previewHint, NSLocalizedString("photo", comment: ""))
    }

    func testAReplyToAVideoNoteSaysSoLocallyAndVideoOnTheWire() throws {
        let content = MediaWireCodec.albumContent(mediaList: [item(.videoNote)], caption: "", quoted: nil)
        let json = try XCTUnwrap(MediaWireCodec.mediaJSON(from: content.mediaAlbum))
        let reply = try XCTUnwrap(ReplyPreviewPayload.projecting(originalContent: json))
        XCTAssertEqual(reply.kind, .videoNote)
        XCTAssertEqual(reply.localizedDisplayText, NSLocalizedString("video_note", comment: ""))
        XCTAssertEqual(reply.protoMediaType, .video)
    }
}
