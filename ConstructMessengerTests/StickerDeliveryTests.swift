//
//  StickerDeliveryTests.swift
//  ConstructMessengerTests
//
//  The receive path: a valid sticker becomes a row whose stored payload reads back as the same
//  reference, an invalid one is refused before anything is stored, and the previews say what
//  the chat list should.
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class StickerDeliveryTests: XCTestCase {

    private var validRef: StickerReference {
        StickerReference(pack: StickerPackID(Data(repeating: 0xA5, count: 32))!, index: 3, emoji: "🟡")!
    }

    private func content(_ wire: Shared_Proto_Messaging_V1_StickerRef) -> Data {
        var c = Shared_Proto_Messaging_V1_MessageContent()
        c.sticker = wire
        return try! c.serializedData()
    }

    /// Decoded, stored as CTM1 `messageContent`, and read back typed — the same reference at
    /// both ends, with no text form in between.
    func testValidStickerIsAssembledAndReadsBackTyped() throws {
        let ref = validRef
        switch ChunkedMessageReassembler.shared.decodeAssembled(content(ref.wire), e2eMessageId: "abc") {
        case .assembled(let text, _, let e2eId, let album, let storage):
            XCTAssertEqual(text, "", "a sticker has no text form")
            XCTAssertEqual(e2eId, "abc")
            XCTAssertNil(album)
            let payload = LocalMessagePayload.decode(try XCTUnwrap(storage))
            XCTAssertEqual(payload.stickerReference, ref)
            XCTAssertEqual(payload.displayString, "")
            XCTAssertEqual(payload.previewHint, "🟡 \(NSLocalizedString("sticker", comment: ""))")
        default:
            XCTFail("expected .assembled")
        }
    }

    /// Mutation: drop the `rejectedSticker` gate — this becomes an `.assembled` row with empty
    /// text and a nil reference, indistinguishable from a message that arrived empty.
    func testInvalidStickerIsRefusedNotStored() {
        let bad = Shared_Proto_Messaging_V1_StickerRef.with {
            $0.packID = Data(repeating: 1, count: 31)
            $0.index = 0
            $0.emoji = "🟡"
        }
        for site in ["assembled", "raw"] {
            let result = site == "assembled"
                ? ChunkedMessageReassembler.shared.decodeAssembled(content(bad), e2eMessageId: nil)
                : ChunkedMessageReassembler.shared.process(data: content(bad), envelopeId: "env-\(UUID().uuidString)")
            guard case .invalid(let why) = result else {
                XCTFail("\(site): expected .invalid, got \(result)"); continue
            }
            XCTAssertTrue(why.contains("sticker"), why)
        }
    }

    /// A text payload is untouched by the gate: the sticker check is a sticker check.
    func testTextStillAssembles() {
        var c = Shared_Proto_Messaging_V1_MessageContent()
        c.text = .with { $0.text = "hi" }
        guard case .assembled(let text, _, _, _, _) = ChunkedMessageReassembler.shared.decodeAssembled(try! c.serializedData(), e2eMessageId: nil) else {
            return XCTFail("expected .assembled")
        }
        XCTAssertEqual(text, "hi")
    }

    /// A stored payload that is not a sticker answers nil, cheaply, for every other kind.
    func testNonStickerPayloadsHaveNoReference() {
        XCTAssertNil(LocalMessagePayload.decode(LocalMessagePayload.encodeText("hi")).stickerReference)
        var c = Shared_Proto_Messaging_V1_MessageContent()
        c.text = .with { $0.text = "hi" }
        XCTAssertNil(LocalMessagePayload.decode(LocalMessagePayload.encodeMessageContent(c)).stickerReference)
    }
}
