//
//  ReactionWireTests.swift
//  ConstructMessengerTests
//
//  timestamp_ms is protobuf field 4. Generated Swift does not expose it yet;
//  ReactionWire writes/reads the varint. A send without that clock would make
//  every replica fight over envelope time.
//

import XCTest
import SwiftProtobuf
@testable import Construct_Messenger

final class ReactionWireTests: XCTestCase {

    private let target = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let t0: Int64 = 1_700_000_000_000

    func testEncode_RoundTripsTimestampThroughDecode() throws {
        let plan = ReactionReducer.SendPlan(
            targetMessageId: target,
            incoming: .add(emoji: "❤️"),
            timestampMs: t0
        )
        let data = try XCTUnwrap(ReactionWire.encode(plan))

        switch ChunkedMessageReassembler.shared.decodeAssembled(data, e2eMessageId: nil) {
        case .reaction(let decodedTarget, let emoji, let action, let timestampMs):
            XCTAssertEqual(decodedTarget, target)
            XCTAssertEqual(emoji, "❤️")
            XCTAssertEqual(action, .add)
            XCTAssertEqual(timestampMs, t0, "field 4 must survive decode or LWW is envelope time")
        case .assembled(let text, _, _, _, _):
            XCTFail("encoded reaction became assembled text \(text.debugDescription) — blank bubble")
        default:
            XCTFail("encoded reaction must decode as .reaction")
        }
    }

    func testEncodeRemove_HasEmptyEmojiAndRemoveAction() throws {
        let plan = ReactionReducer.SendPlan(
            targetMessageId: target,
            incoming: .remove,
            timestampMs: t0
        )
        let data = try XCTUnwrap(ReactionWire.encode(plan))
        switch ChunkedMessageReassembler.shared.decodeAssembled(data, e2eMessageId: nil) {
        case .reaction(_, let emoji, let action, let timestampMs):
            XCTAssertEqual(emoji, "")
            XCTAssertEqual(action, .remove)
            XCTAssertEqual(timestampMs, t0)
        default:
            XCTFail("remove must decode as .reaction")
        }
    }

    func testLegacyPayloadWithoutField4_TimestampIsZero() throws {
        var reaction = Shared_Proto_Messaging_V1_ReactionMessage()
        reaction.targetMessageID = target
        reaction.emoji = "🔥"
        reaction.action = .add
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.reaction = reaction
        let data = try content.serializedData()

        switch ChunkedMessageReassembler.shared.decodeAssembled(data, e2eMessageId: nil) {
        case .reaction(_, _, _, let timestampMs):
            XCTAssertEqual(timestampMs, 0)
        default:
            XCTFail("legacy reaction must still decode as .reaction")
        }
    }

    // `testInt64Field_RoundTrips` was here, over a hand-rolled varint encoder. It is gone with the
    // encoder: `timestamp_ms` is a generated property now, so what it tested is SwiftProtobuf's.
    // The two tests above still cover the property that matters — a stamped reaction round-trips,
    // and one from a peer that never wrote the field decodes as 0 rather than failing.
}
