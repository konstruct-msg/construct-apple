//
//  AudioFileMessageTests.swift
//  ConstructMessengerTests
//
//  A music file is a file. Until 2026-10-13 an album of `audio/` items was read as pictures:
//  the bubble was an empty image with no player and the chat list said "Photo". The row is built
//  from the stored album on every read, so rows received before the fix read correctly too.
//

import XCTest
@testable import Construct_Messenger

final class AudioFileMessageTests: XCTestCase {

    private func item(_ mime: String, _ filename: String) -> Shared_Proto_Messaging_V1_MediaMessage {
        var item = Shared_Proto_Messaging_V1_MediaMessage()
        item.mediaID = UUID().uuidString
        item.mimeType = mime
        item.fileSize = 4_200_000
        item.filename = filename
        item.encryptionKey = Data(repeating: 0x07, count: 32)
        return item
    }

    private func album(_ items: Shared_Proto_Messaging_V1_MediaMessage...) -> Shared_Proto_Messaging_V1_MediaAlbumMessage {
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = items
        return album
    }

    func testATrackIsShownAsAFileRow() throws {
        let stored = LocalMessagePayload.decode(LocalMessagePayload.encodeMediaAlbum(album(item("audio/mpeg", "song.mp3"))))
        let file = try XCTUnwrap(MessageBubbleContentParsing.parseFileMessage(stored.displayString),
                                 "the file row is the one with a player")
        XCTAssertEqual(file.files.map(\.filename), ["song.mp3"])
        XCTAssertNil(MessageBubbleContentParsing.parseMediaMessage(stored.displayString),
                     "the picture bubble has no audio case")
    }

    /// The receive path stores the whole `MessageContent`, not the bare album.
    func testATrackReceivedAsMessageContentIsShownAsAFileRow() {
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.mediaAlbum = album(item("audio/flac", "take.flac"))
        let stored = LocalMessagePayload.decode(LocalMessagePayload.encodeMessageContent(content))
        XCTAssertNotNil(MessageBubbleContentParsing.parseFileMessage(stored.displayString))
        XCTAssertEqual(stored.previewHint, NSLocalizedString("audio_file", comment: ""))
    }

    func testTheChatListNamesATrackAudio() {
        let stored = LocalMessagePayload.decode(LocalMessagePayload.encodeMediaAlbum(album(item("audio/mpeg", "song.mp3"))))
        XCTAssertEqual(stored.previewHint, NSLocalizedString("audio_file", comment: ""))
        XCTAssertNotEqual(stored.previewHint, NSLocalizedString("photo", comment: ""))
    }

    func testADocumentIsStillAFile() {
        let stored = LocalMessagePayload.decode(LocalMessagePayload.encodeMediaAlbum(album(item("application/pdf", "a.pdf"))))
        XCTAssertEqual(stored.previewHint, NSLocalizedString("file", comment: ""))
    }

    func testTracksSentWithADocumentAreFilesNamedFile() {
        let mixed = album(item("audio/mpeg", "song.mp3"), item("application/pdf", "lyrics.pdf"))
        XCTAssertTrue(MediaWireCodec.looksLikeFileAlbum(mixed))
        XCTAssertFalse(MediaWireCodec.isAudioAlbum(mixed))
    }

    func testAnAlbumWithAPictureStaysPictures() {
        let withPhoto = album(item("image/jpeg", "a.jpg"), item("audio/mpeg", "song.mp3"))
        XCTAssertFalse(MediaWireCodec.looksLikeFileAlbum(withPhoto))
    }

    func testClearingATracksCaptionNamesItAudio() throws {
        var track = album(item("audio/mpeg", "song.mp3"))
        track.caption = "listen"
        let edited = try XCTUnwrap(MediaWireCodec.editedCaptionPayload(
            storedPlaintext: LocalMessagePayload.encodeMediaAlbum(track), newCaption: ""))
        XCTAssertEqual(edited.displayPreview, NSLocalizedString("audio_file", comment: ""))
    }

    func testEveryAcceptedAudioFormatGetsTheTrackIcon() {
        for ext in MessageSizeLimits.supportedAudioTypes {
            XCTAssertEqual(FileAttachmentBubbleView.symbolName(for: "x.\(ext)"), "waveform", ext)
            XCTAssertTrue(MessageSizeLimits.isFileTypeSupported(ext), ext)
        }
        XCTAssertTrue(MessageSizeLimits.isFileTypeSupported("opus"))
    }
}
