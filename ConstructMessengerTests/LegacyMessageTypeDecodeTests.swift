//
//  LegacyMessageTypeDecodeTests.swift
//  ConstructMessengerTests
//
//  `ChatMessage.messageType` was removed on 2026-08-02: a second representation of the same fact
//  as `contentType`, written at twelve sites and read at none. A disagreement between the two is
//  what shipped the sealed control-channel outage.
//
//  A compatibility read for the old storage key was written alongside the removal and then
//  removed too, once it was clear there is no population to be compatible with — the app has
//  never shipped, so every device in the tester circle migrates in one step. These tests pin the
//  end state rather than the migration: the byte is the only type, and the removed field must not
//  come back through the encoder or through a decoder that quietly honours it.
//
//  If a compatibility read is ever reintroduced, testLegacyKeyIsIgnored goes red — which is the
//  point. Reintroducing it means reintroducing the duplicate.
//

import XCTest
@testable import Construct_Messenger

final class LegacyMessageTypeDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> ChatMessage {
        try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    }

    /// The byte is the only input to routing.
    func testContentTypeDrivesRouting() throws {
        let endSession = try decode(#"{"id":"m-1","from":"peer","to":"me","contentType":21}"#)
        XCTAssertTrue(endSession.isEndSession)
        XCTAssertFalse(endSession.isSessionResetInit)

        let sri = try decode(#"{"id":"m-2","from":"peer","to":"me","contentType":24}"#)
        XCTAssertTrue(sri.isSessionResetInit)

        let sync = try decode(#"{"id":"m-3","from":"peer","to":"me","contentType":23}"#)
        XCTAssertTrue(sync.isSenderSync)
    }

    /// A stray `messageType` key must have no effect whatsoever — not as a fallback, not as an
    /// override. It is not a second opinion; it is not an opinion.
    func testLegacyKeyIsIgnored() throws {
        let onlyLegacy = try decode(#"{"id":"m-4","from":"peer","to":"me","messageType":"CONTROL_MESSAGE"}"#)
        XCTAssertEqual(onlyLegacy.contentType, 0,
                       "the removed key must not be promoted — that is the duplicate coming back")
        XCTAssertFalse(onlyLegacy.isEndSession)

        let contradicting = try decode(
            #"{"id":"m-5","from":"peer","to":"me","messageType":"DIRECT_MESSAGE","contentType":21}"#
        )
        XCTAssertTrue(contradicting.isEndSession, "the byte stands alone; nothing can contradict it")
    }

    /// Control envelopes legitimately omit almost everything — decoding must not throw.
    func testRowWithNoTypeAtAll_Decodes() throws {
        let bare = try decode(#"{"id":"m-6","from":"peer","to":"me"}"#)
        XCTAssertEqual(bare.contentType, 0)
    }

    /// The field must never reappear in storage.
    func testEncodeNeverWritesMessageType() throws {
        let message = ChatMessage(
            id: "m-7", from: "peer", to: "me",
            ephemeralPublicKey: Data(), messageNumber: 0, content: Data(),
            suiteId: 1, timestamp: 1_000_000, contentType: 21
        )
        let text = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)

        XCTAssertFalse(text.contains("messageType"), "the removed field must not reappear in storage")
        XCTAssertTrue(text.contains("contentType"))
        XCTAssertTrue(try decode(text).isEndSession, "round trip preserves the routing type")
    }
}
