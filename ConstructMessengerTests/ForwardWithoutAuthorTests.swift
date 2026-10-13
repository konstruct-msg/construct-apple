//
//  ForwardWithoutAuthorTests.swift
//  ConstructMessengerTests
//
//  Owner's rule (2026-10-13): nobody may learn whom a forwarded message is from. A forward is an
//  ordinary send of the content alone, and its media goes up as a new object — never the
//  original's, which would tie the two conversations together for the server.
//

import XCTest
@testable import Construct_Messenger

final class ForwardWithoutAuthorTests: XCTestCase {

    private let key = Data(repeating: 0x2A, count: 32)

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    // MARK: - What is carried

    func testTextIsCarriedAsItsWordsAlone() {
        XCTAssertEqual(ForwardItem.content(legacyBody: "hello", plainText: "  hello \n", sticker: nil), .text("hello"))
    }

    func testPhotosCarryTheirCaptionAndAPointerToTheLocalCopy() throws {
        let body = json(["type": "media", "caption": "look", "media": [
            ["mediaId": "m1", "mediaUrl": "u1", "mediaKey": key.base64EncodedString(), "mediaType": "image/jpeg"],
            ["mediaId": "m2", "mediaUrl": "u2", "mediaKey": key.base64EncodedString(), "mediaType": "video/mp4",
             "duration": 3.5, MediaPresentation.jsonKey: MediaPresentation.videoNote.rawValue],
        ]])
        guard case .media(let items, let caption)? = ForwardItem.content(legacyBody: body, plainText: nil, sticker: nil)
        else { return XCTFail("not media") }
        XCTAssertEqual(caption, "look")
        XCTAssertEqual(items.map(\.mediaId), ["m1", "m2"])
        XCTAssertEqual(items[1].presentation, .videoNote)
        XCTAssertEqual(items[1].duration, 3.5)
    }

    func testAnAlbumWithAnItemThatCannotBeOpenedIsNotForwardedHalf() {
        let body = json(["type": "media", "caption": "", "media": [
            ["mediaId": "m1", "mediaUrl": "u1", "mediaKey": key.base64EncodedString(), "mediaType": "image/jpeg"],
            ["mediaId": "m2", "mediaUrl": "u2", "mediaType": "image/jpeg"],
        ]])
        XCTAssertNil(ForwardItem.content(legacyBody: body, plainText: nil, sticker: nil))
    }

    func testFilesKeepTheirNames() {
        let body = json(["type": "file", "caption": "", "files": [
            ["mediaId": "f1", "mediaUrl": "u", "mediaKey": key.base64EncodedString(), "mediaType": "audio/mpeg",
             "size": 10, "hash": "00", "filename": "song.mp3"],
        ]])
        guard case .files(let items, _)? = ForwardItem.content(legacyBody: body, plainText: nil, sticker: nil)
        else { return XCTFail("not files") }
        XCTAssertEqual(items.map(\.filename), ["song.mp3"])
    }

    func testAVoiceMessageKeepsItsLengthAndWaveform() {
        let body = json(["type": "voice", "mediaId": "v1", "mediaUrl": "u", "mediaKey": key.base64EncodedString(),
                         "mediaType": "audio/m4a", "size": 10, "duration": 4.0, "waveform": [0.5, 1.0], "hash": "00"])
        guard case .voice(let audio, let duration, let waveform)? = ForwardItem.content(legacyBody: body, plainText: nil, sticker: nil)
        else { return XCTFail("not voice") }
        XCTAssertEqual(audio.mediaId, "v1")
        XCTAssertEqual(duration, 4.0)
        XCTAssertEqual(waveform, [0.5, 1.0])
    }

    /// A shared profile means "this is who shared it" — forwarding it would carry exactly that.
    func testASharedProfileIsNotForwarded() {
        let body = json(["type": "profile", "displayName": "n", "timestamp": 1])
        XCTAssertNotNil(MessageBubbleContentParsing.parseProfileMessage(body), "the fixture must be a profile")
        // A row stored before CTM1 answers `plainText` with the JSON itself.
        XCTAssertNil(ForwardItem.content(legacyBody: body, plainText: body, sticker: nil))
    }

    func testAnUploadStillInFlightIsNotForwarded() {
        let body = json(["type": "media", "caption": "", "media": [["_placeholder": true]]])
        XCTAssertTrue(UploadPlaceholderBody.isSentinel(body))
        XCTAssertNil(ForwardItem.content(legacyBody: body, plainText: body, sticker: nil))
    }

    // MARK: - A new object, never the original's

    func testAStagedCopyIsUploadedAsANewObject() throws {
        let staged = try ForwardStaging.newFileURL(named: "song.mp3")
        defer { ForwardStaging.discard(staged) }
        XCTAssertEqual(staged.lastPathComponent, "song.mp3", "the name is what the recipient sees")
        XCTAssertEqual(ForwardStaging.reuse(for: staged), .freshObject)
    }

    func testAFileThePersonPickedMayReuseAnEarlierUpload() {
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent("picked.mp3")
        XCTAssertEqual(ForwardStaging.reuse(for: picked), .sameBytesSameObject)
        let lookalike = FileManager.default.temporaryDirectory.appendingPathComponent("forwarded/x.mp3")
        XCTAssertEqual(ForwardStaging.reuse(for: lookalike), .sameBytesSameObject)
    }

    func testDiscardRemovesOnlyStagedCopies() throws {
        let staged = try ForwardStaging.newFileURL(named: "a.txt")
        try Data("x".utf8).write(to: staged)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("y".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        ForwardStaging.discard(staged)
        ForwardStaging.discard(elsewhere)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    func testAFreshUploadIsNeverRecordedForReuse() async {
        let bytes = Data(UUID().uuidString.utf8)
        let upload = MediaServiceClient.UploadedMedia(
            mediaId: UUID().uuidString, mediaUrl: "u", encryptionKey: key, encryptedSize: 1, hash: "00", mimeType: "image/jpeg")
        await MediaSendCache.shared.storeUpload(upload, for: bytes, reuse: .freshObject)
        let found = await MediaSendCache.shared.cachedUpload(for: bytes)
        XCTAssertNil(found, "a later ordinary send of the same bytes would reuse the forward's object")
    }

    func testAFreshUploadNeverReusesAnEarlierOne() async {
        let bytes = Data(UUID().uuidString.utf8)
        let earlier = MediaServiceClient.UploadedMedia(
            mediaId: UUID().uuidString, mediaUrl: "u", encryptionKey: key, encryptedSize: 1, hash: "00", mimeType: "image/jpeg")
        await MediaSendCache.shared.storeUpload(earlier, for: bytes)
        let ordinary = await MediaSendCache.shared.cachedUpload(for: bytes)
        XCTAssertEqual(ordinary?.mediaId, earlier.mediaId, "the fixture must be in the cache")
        let forward = await MediaSendCache.shared.cachedUpload(for: bytes, reuse: .freshObject)
        XCTAssertNil(forward)
    }
}
