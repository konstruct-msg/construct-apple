//
//  LegacyMessageTypeDecodeTests.swift
//  ConstructMessengerTests
//
//  `ChatMessage.messageType` was removed on 2026-08-02: it was a second representation of the
//  same fact as `contentType`, written at twelve sites and read at none, and a disagreement
//  between the two is what shipped the sealed control-channel outage.
//
//  One thing survived the removal on purpose: the *storage key*. `ChatMessage` is persisted as
//  JSON by `SessionHealingService`, `FailedInitMessageStore` and the pending queue, and a row
//  written by an older build carries `messageType` with no `contentType`. Decoding that row
//  without promoting the byte would leave `contentType == 0`, so every predicate reads false and
//  a queued END_SESSION or SESSION_RESET_INIT comes back as an ordinary message.
//
//  `LegacyCodingKeys` therefore looks like dead code and is not. These tests are what stands
//  between it and the next cleanup.
//
//  Acceptance is mutation-based: delete the `LegacyCodingKeys` read in `init(from:)` and
//  testLegacyRow_PromotesContentTypeFromMessageType must go red.
//

import XCTest
@testable import Construct_Messenger

final class LegacyMessageTypeDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> ChatMessage {
        try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    }

    /// The row shape an older build persisted: a kind string, no content byte.
    private func legacyJSON(kind: String) -> String {
        """
        {"id":"m-1","from":"peer","to":"me","messageType":"\(kind)"}
        """
    }

    func testLegacyRow_PromotesContentTypeFromMessageType() throws {
        let endSession = try decode(legacyJSON(kind: "CONTROL_MESSAGE"))
        XCTAssertEqual(endSession.contentType, 21)
        XCTAssertTrue(endSession.isEndSession, "a queued END_SESSION must still route as one")

        let sri = try decode(legacyJSON(kind: "SESSION_RESET_INIT"))
        XCTAssertEqual(sri.contentType, 24)
        XCTAssertTrue(sri.isSessionResetInit)

        let sync = try decode(legacyJSON(kind: "SENDER_SYNC"))
        XCTAssertEqual(sync.contentType, 23)
        XCTAssertTrue(sync.isSenderSync)
    }

    /// A regular legacy row must stay regular — the promotion is for control kinds only.
    func testLegacyRegularRow_StaysContentTypeZero() throws {
        let direct = try decode(legacyJSON(kind: "DIRECT_MESSAGE"))
        XCTAssertEqual(direct.contentType, 0)
        XCTAssertFalse(direct.isEndSession)
    }

    /// A current row carries the byte and must win outright: the byte is the authority, and a
    /// stale kind string alongside it must not override the recovered type.
    func testCurrentRow_ContentTypeWinsOverLegacyKind() throws {
        let mixed = try decode("""
        {"id":"m-2","from":"peer","to":"me","messageType":"DIRECT_MESSAGE","contentType":21}
        """)
        XCTAssertEqual(mixed.contentType, 21)
        XCTAssertTrue(mixed.isEndSession, "the byte is authoritative; the legacy string is not")
    }

    /// A row with neither key decodes rather than throwing — control envelopes legitimately
    /// omit most fields.
    func testRowWithNoTypeAtAll_Decodes() throws {
        let bare = try decode("""
        {"id":"m-3","from":"peer","to":"me"}
        """)
        XCTAssertEqual(bare.contentType, 0)
    }

    /// We read the legacy key but must never write it again — otherwise the field is back on
    /// the wire and the two representations return with it.
    func testEncodeNeverWritesMessageType() throws {
        let message = ChatMessage(
            id: "m-4", from: "peer", to: "me",
            ephemeralPublicKey: Data(), messageNumber: 0, content: Data(),
            suiteId: 1, timestamp: 1_000_000, contentType: 21
        )
        let encoded = try JSONEncoder().encode(message)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains("messageType"), "the removed field must not reappear in storage")
        XCTAssertTrue(text.contains("contentType"))

        // And the round trip preserves the routing type.
        XCTAssertTrue(try decode(text).isEndSession)
    }
}
