import XCTest
@testable import Construct_Messenger

final class ServerMessageOrderTests: XCTestCase {

    func testServerOrderUsesMillisecondThenSequence() {
        let first = ServerMessageOrder.key(serverTimestampMilliseconds: 1_700_000_001, sequence: 9)
        let second = ServerMessageOrder.key(serverTimestampMilliseconds: 1_700_000_001, sequence: 10)
        let later = ServerMessageOrder.key(serverTimestampMilliseconds: 1_700_000_002, sequence: 0)

        XCTAssertEqual(first, "00000000001700000001-00000000000000000009")
        XCTAssertLessThan(first ?? "", second ?? "")
        XCTAssertLessThan(second ?? "", later ?? "")
    }

    func testStreamCursorSuppliesSequenceWhenMetadataHasOnlyTimestamp() {
        let key = ServerMessageOrder.key(
            serverTimestampMilliseconds: 1_700_000_001,
            sequence: 0,
            cursor: "1700000001-42"
        )

        XCTAssertEqual(key, "00000000001700000001-00000000000000000042")
    }

    func testSendAckWithoutServerTimestampDoesNotCreateFakeOrder() {
        XCTAssertNil(
            ServerMessageOrder.key(serverTimestampMilliseconds: 0, sequence: 42),
            "zero is the generated-proto default, not an authoritative server position"
        )
    }

    func testPendingKeySortsAfterAuthoritativeServerKeys() {
        let pending = ServerMessageOrder.pending(localMessageId: "LOCAL")
        let server = ServerMessageOrder.key(serverTimestampMilliseconds: 9_999_999_999, sequence: 9_999)!

        XCTAssertGreaterThan(pending, server)
        XCTAssertTrue(pending.hasSuffix("-local"))
    }

    func testStreamParserCarriesEnvelopeMetadataAndCursorIntoChatMessage() {
        var envelope = Shared_Proto_Core_V1_Envelope()
        envelope.messageID = "message-id"
        envelope.sender.userID = "sender"
        envelope.recipient.userID = "recipient"
        envelope.timestamp = 1
        envelope.contentType = .sessionReset
        envelope.serverMetadata.serverTimestamp = 1_700_000_001_001
        envelope.serverMetadata.messageNumber = 7

        var response = Shared_Proto_Services_V1_MessageStreamResponse()
        response.message = envelope
        response.streamCursor = "1700000001001-42"

        guard case .message(let message, let cursor)? = MessageStreamParser.parse(response) else {
            return XCTFail("expected a parsed message event")
        }

        XCTAssertEqual(cursor, "1700000001001-42")
        XCTAssertEqual(
            message.serverOrderKey,
            ServerMessageOrder.key(
                serverTimestampMilliseconds: 1_700_000_001_001,
                sequence: 7,
                cursor: "1700000001001-42"
            )
        )
    }
}
