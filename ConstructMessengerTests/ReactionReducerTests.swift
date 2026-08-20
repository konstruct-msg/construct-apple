//
//  ReactionReducerTests.swift
//  ConstructMessengerTests
//
//  Pins the reaction apply table in MESSAGE_REACTIONS_SPEC. A reaction is
//  metadata, never a chat row: decode must return `.reaction`, not `.assembled`
//  with empty text (the blank-bubble leak).
//

import XCTest
import SwiftProtobuf
@testable import Construct_Messenger

final class ReactionReducerTests: XCTestCase {

    private let target = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let t0: Int64 = 1_700_000_000_000
    private let t1: Int64 = 1_700_000_000_500

    // MARK: - Apply

    func testAddOnEmpty_Sets() {
        XCTAssertEqual(
            ReactionReducer.apply(
                existing: nil,
                incoming: .add(emoji: "❤️"),
                timestampMs: t0,
                targetMessageId: target
            ),
            .set(emoji: "❤️", timestampMs: t0)
        )
    }

    func testNewerAdd_Replaces() {
        let existing = ReactionReducer.Row(emoji: "😂", timestampMs: t0)
        XCTAssertEqual(
            ReactionReducer.apply(
                existing: existing,
                incoming: .add(emoji: "🔥"),
                timestampMs: t1,
                targetMessageId: target
            ),
            .set(emoji: "🔥", timestampMs: t1)
        )
    }

    func testOlderAdd_IsKeptOut() {
        let existing = ReactionReducer.Row(emoji: "❤️", timestampMs: t1)
        XCTAssertEqual(
            ReactionReducer.apply(
                existing: existing,
                incoming: .add(emoji: "😂"),
                timestampMs: t0,
                targetMessageId: target
            ),
            .keepExisting,
            "LWW: a slower replica must not overwrite"
        )
    }

    func testTie_KeepsExisting() {
        let existing = ReactionReducer.Row(emoji: "❤️", timestampMs: t0)
        XCTAssertEqual(
            ReactionReducer.apply(
                existing: existing,
                incoming: .add(emoji: "😂"),
                timestampMs: t0,
                targetMessageId: target
            ),
            .keepExisting,
            "equal clocks: first-write stays, so redelivery is a no-op"
        )
    }

    func testNewerRemove_Clears() {
        let existing = ReactionReducer.Row(emoji: "❤️", timestampMs: t0)
        XCTAssertEqual(
            ReactionReducer.apply(
                existing: existing,
                incoming: .remove,
                timestampMs: t1,
                targetMessageId: target
            ),
            .clear
        )
    }

    func testRemoveWithNoRow_IsNoOp() {
        XCTAssertEqual(
            ReactionReducer.apply(
                existing: nil,
                incoming: .remove,
                timestampMs: t0,
                targetMessageId: target
            ),
            .keepExisting
        )
    }

    func testEmptyTarget_IsInvalid() {
        XCTAssertEqual(
            ReactionReducer.apply(
                existing: nil,
                incoming: .add(emoji: "❤️"),
                timestampMs: t0,
                targetMessageId: ""
            ),
            .dropInvalid
        )
    }

    func testNilIncoming_IsInvalid() {
        XCTAssertEqual(
            ReactionReducer.apply(
                existing: nil,
                incoming: nil,
                timestampMs: t0,
                targetMessageId: target
            ),
            .dropInvalid
        )
    }

    // MARK: - Incoming mapping

    func testUnspecifiedWithEmoji_IsAdd() {
        XCTAssertEqual(ReactionReducer.incoming(actionRawValue: 0, emoji: "😮"), .add(emoji: "😮"))
    }

    func testAddWithEmptyEmoji_IsRejected() {
        XCTAssertNil(ReactionReducer.incoming(actionRawValue: 1, emoji: ""))
    }

    func testRemoveIgnoresEmoji() {
        XCTAssertEqual(ReactionReducer.incoming(actionRawValue: 2, emoji: ""), .remove)
        XCTAssertEqual(ReactionReducer.incoming(actionRawValue: 2, emoji: "❤️"), .remove)
    }

    func testUnknownAction_IsRejected() {
        XCTAssertNil(ReactionReducer.incoming(actionRawValue: 99, emoji: "❤️"))
    }

    // MARK: - Local toggle

    func testRepeatTap_Removes() {
        XCTAssertEqual(ReactionReducer.localToggle(currentEmoji: "❤️", tapped: "❤️"), .remove)
    }

    func testDifferentTap_Replaces() {
        XCTAssertEqual(ReactionReducer.localToggle(currentEmoji: "❤️", tapped: "🔥"), .add(emoji: "🔥"))
    }

    func testFirstTap_Adds() {
        XCTAssertEqual(ReactionReducer.localToggle(currentEmoji: nil, tapped: "😂"), .add(emoji: "😂"))
    }

    func testQuickSet_IsTheInstagramSix() {
        XCTAssertEqual(ReactionReducer.quickSet, ["❤️", "😂", "😮", "😢", "😠", "🔥"])
    }

    // MARK: - Clock + orphan

    func testZeroPayloadTimestamp_UsesFallback() {
        XCTAssertEqual(ReactionReducer.normalizeTimestamp(payloadMs: 0, fallbackMs: t0), t0)
        XCTAssertEqual(ReactionReducer.normalizeTimestamp(payloadMs: t1, fallbackMs: t0), t1)
    }

    func testOrphanEvictedAfterSevenDays() {
        let received = t0
        let sixDays = received + 6 * 24 * 60 * 60 * 1000
        let sevenDays = received + 7 * 24 * 60 * 60 * 1000
        XCTAssertFalse(ReactionReducer.shouldEvictOrphan(targetExists: false, receivedAtMs: received, nowMs: sixDays))
        XCTAssertTrue(ReactionReducer.shouldEvictOrphan(targetExists: false, receivedAtMs: received, nowMs: sevenDays))
        XCTAssertFalse(ReactionReducer.shouldEvictOrphan(targetExists: true, receivedAtMs: received, nowMs: sevenDays),
                       "a reaction whose target arrived must not be swept as an orphan")
    }

    // MARK: - Not a chat row

    /// If this oneof is decoded as `.assembled` with empty text, the router persists a blank
    /// bubble. That is the `__session_ready_` leak class. The branch must exist before any send.
    func testReactionProtobuf_DecodesAsReactionNotEmptyAssembled() throws {
        var reaction = Shared_Proto_Messaging_V1_ReactionMessage()
        reaction.targetMessageID = target
        reaction.emoji = "❤️"
        reaction.action = .add
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.reaction = reaction
        let data = try content.serializedData()

        switch ChunkedMessageReassembler.shared.decodeAssembled(data, e2eMessageId: nil) {
        case .reaction(let decodedTarget, let emoji, let action, let timestampMs):
            XCTAssertEqual(decodedTarget, target)
            XCTAssertEqual(emoji, "❤️")
            XCTAssertEqual(action, .add)
            XCTAssertEqual(timestampMs, 0, "timestamp_ms is not in generated Swift until proto regen; 0 is the dual-read")
        case .assembled(let text, _, _, _, _):
            XCTFail("reaction became assembled text \(text.debugDescription) — that is a blank bubble")
        default:
            XCTFail("reaction must decode as .reaction")
        }
    }

    func testTextProtobuf_IsStillAssembled() throws {
        var text = Shared_Proto_Messaging_V1_TextMessage()
        text.text = "hello"
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.text = text
        let data = try content.serializedData()
        switch ChunkedMessageReassembler.shared.decodeAssembled(data, e2eMessageId: nil) {
        case .assembled(let body, _, _, _, _):
            XCTAssertEqual(body, "hello")
        default:
            XCTFail("ordinary text must stay a visible assembled message")
        }
    }
}
