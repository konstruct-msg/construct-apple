//
//  HistoryBodyCodecTests.swift
//  ConstructMessengerTests
//
//  Wire oneof ↔ CTM1. utf8Text lifts to MessageContent and stores as
//  messageContent CTM1 — that is K14, not a round-trip of the old kind byte.
//

import XCTest
import SwiftProtobuf
@testable import Construct_Messenger

final class HistoryBodyCodecTests: XCTestCase {

    private func textBody(_ s: String) -> Construct_Client_History_V1_HistoryMessage.OneOf_Body {
        var t = Shared_Proto_Messaging_V1_TextMessage()
        t.text = s
        var c = Shared_Proto_Messaging_V1_MessageContent()
        c.text = t
        return .messageContent(c)
    }

    func testLiftStoreRoundTripOfEachOneofCase() throws {
        let text = textBody("hello")
        XCTAssertEqual(HistoryBodyCodec.lift(stored: LocalMessagePayload.decode(try HistoryBodyCodec.store(text))), text)

        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.caption = "cap"
        var item = Shared_Proto_Messaging_V1_MediaMessage()
        item.mediaID = "media-1"
        item.mimeType = "image/jpeg"
        album.items = [item]
        let albumBody = Construct_Client_History_V1_HistoryMessage.OneOf_Body.mediaAlbum(album)
        let storedAlbum = try HistoryBodyCodec.store(albumBody)
        XCTAssertEqual(HistoryBodyCodec.lift(stored: LocalMessagePayload.decode(storedAlbum)), albumBody)

        let profile = Data([0x01, 0x03, 0x00, 0x42, 0x6F, 0x62, 0x00, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 8))
        let share = Construct_Client_History_V1_HistoryMessage.OneOf_Body.profileShare(profile)
        let storedShare = try HistoryBodyCodec.store(share)
        XCTAssertEqual(HistoryBodyCodec.lift(stored: LocalMessagePayload.decode(storedShare)), share)
    }

    func testStoreOfMessageContentIsTheReassemblerMapping() throws {
        let body = textBody("wire")
        let stored = try HistoryBodyCodec.store(body)
        XCTAssertEqual(stored, LocalMessagePayload.storagePayload(forWireContent: {
            var t = Shared_Proto_Messaging_V1_TextMessage()
            t.text = "wire"
            var c = Shared_Proto_Messaging_V1_MessageContent()
            c.text = t
            return c
        }()))
        XCTAssertTrue(stored.starts(with: LocalMessagePayload.magic))
        XCTAssertEqual(stored[4], LocalMessagePayloadKind.messageContent.rawValue)
    }

    func testStoreThenLiftOfCTM1MessageContentAndAlbumAndProfile() throws {
        var content = Shared_Proto_Messaging_V1_MessageContent()
        var t = Shared_Proto_Messaging_V1_TextMessage()
        t.text = "ctm1"
        content.text = t
        let ctm1 = LocalMessagePayload.encodeMessageContent(content)
        XCTAssertEqual(
            try HistoryBodyCodec.store(try XCTUnwrap(HistoryBodyCodec.lift(stored: LocalMessagePayload.decode(ctm1)))),
            ctm1
        )

        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.caption = "a"
        let albumCTM1 = LocalMessagePayload.encodeMediaAlbum(album)
        XCTAssertEqual(
            try HistoryBodyCodec.store(HistoryBodyCodec.lift(stored: LocalMessagePayload.decode(albumCTM1))!),
            albumCTM1
        )

        let blob = Data([0x01, 0x00, 0x00])
        let profileCTM1 = LocalMessagePayload.encodeProfileBinary(blob)
        XCTAssertEqual(
            try HistoryBodyCodec.store(HistoryBodyCodec.lift(stored: LocalMessagePayload.decode(profileCTM1))!),
            profileCTM1
        )
    }

    /// Mutation: utf8Text is shipped as CTM1 kind 0x01 on the wire.
    func testUtf8TextLiftsToMessageContentNotCTM1Kind() throws {
        let stored = LocalMessagePayload.encodeText("plain")
        let lifted = try XCTUnwrap(HistoryBodyCodec.lift(stored: LocalMessagePayload.decode(stored)))
        guard case .messageContent(let c) = lifted, case .text(let t)? = c.content else {
            return XCTFail("utf8Text must lift to MessageContent.text")
        }
        XCTAssertEqual(t.text, "plain")
        let round = try HistoryBodyCodec.store(lifted)
        XCTAssertEqual(round[4], LocalMessagePayloadKind.messageContent.rawValue)
    }

    /// Mutation: legacy UTF-8 text is dropped instead of becoming MessageContent{text}.
    func testLegacyTextLiftsToMessageContent() throws {
        let lifted = try XCTUnwrap(HistoryBodyCodec.lift(stored: .legacyUTF8(Data("hello".utf8))))
        guard case .messageContent(let c) = lifted, case .text(let t)? = c.content else {
            return XCTFail("legacy text must lift to MessageContent.text")
        }
        XCTAssertEqual(t.text, "hello")
    }

    /// Mutation: unconvertible legacy is emitted as opaque bytes.
    func testUnconvertibleLegacyReturnsNil() {
        XCTAssertNil(HistoryBodyCodec.lift(stored: .legacyUTF8(Data([0xFF, 0xFE, 0xFD]))))
        XCTAssertNil(HistoryBodyCodec.lift(stored: .legacyUTF8(Data("{\"type\":\"session_ready\"}".utf8))))
    }

    /// Mutation: a message with no body is applied.
    func testUnsetBodyIsMalformed() {
        let msg = Construct_Client_History_V1_HistoryMessage()
        XCTAssertEqual(HistoryBodyCodec.disposition(of: msg), .malformed)
    }

    /// Mutation: an unknown oneof case is treated as unset (hard fail).
    func testUnknownOneofIsSkippedNotMalformed() throws {
        var msg = Construct_Client_History_V1_HistoryMessage()
        msg.id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        var payload = try msg.serializedData()
        // field 17, length-delimited, 1 byte — a future oneof case.
        payload.append(contentsOf: [0x8A, 0x01, 0x01, 0x00])
        let decoded = try Construct_Client_History_V1_HistoryMessage(serializedBytes: payload)
        XCTAssertNil(decoded.body)
        XCTAssertEqual(HistoryBodyCodec.disposition(of: decoded), .unknownBody)
    }

    func testLegacyMediaJSONLiftsToAlbum() throws {
        let json = "{\"type\":\"media\",\"caption\":\"c\",\"media\":[{\"mediaId\":\"m1\",\"mediaUrl\":\"u\",\"mediaKey\":\"\",\"mediaType\":\"image/jpeg\",\"size\":1,\"hash\":\"\"}]}"
        let lifted = HistoryBodyCodec.lift(stored: .legacyUTF8(Data(json.utf8)))
        guard case .mediaAlbum(let album)? = lifted else {
            return XCTFail("legacy media JSON must lift to media_album")
        }
        XCTAssertEqual(album.items.first?.mediaID, "m1")
    }
}
