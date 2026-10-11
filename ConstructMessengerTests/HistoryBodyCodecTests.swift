//
//  HistoryBodyCodecTests.swift
//  ConstructMessengerTests
//
//  A pre-CTM1 row's body → the wire oneof. CTM1 bodies cross in the core
//  (history::project, its tests).
//

import XCTest
import SwiftProtobuf
@testable import Construct_Messenger

final class HistoryBodyCodecTests: XCTestCase {

    /// Mutation: legacy UTF-8 text is dropped instead of becoming MessageContent{text}.
    func testLegacyTextLiftsToMessageContent() throws {
        let lifted = try XCTUnwrap(HistoryBodyCodec.liftLegacy(Data("hello".utf8)))
        guard case .messageContent(let c) = lifted, case .text(let t)? = c.content else {
            return XCTFail("legacy text must lift to MessageContent.text")
        }
        XCTAssertEqual(t.text, "hello")
    }

    /// Mutation: unconvertible legacy is emitted as opaque bytes.
    func testUnconvertibleLegacyReturnsNil() {
        XCTAssertNil(HistoryBodyCodec.liftLegacy(Data([0xFF, 0xFE, 0xFD])))
        XCTAssertNil(HistoryBodyCodec.liftLegacy(Data("{\"type\":\"session_ready\"}".utf8)))
    }

    func testLegacyMediaJSONLiftsToAlbum() throws {
        let json = "{\"type\":\"media\",\"caption\":\"c\",\"media\":[{\"mediaId\":\"m1\",\"mediaUrl\":\"u\",\"mediaKey\":\"\",\"mediaType\":\"image/jpeg\",\"size\":1,\"hash\":\"\"}]}"
        let lifted = HistoryBodyCodec.liftLegacy(Data(json.utf8))
        guard case .mediaAlbum(let album)? = lifted else {
            return XCTFail("legacy media JSON must lift to media_album")
        }
        XCTAssertEqual(album.items.first?.mediaID, "m1")
    }
}
