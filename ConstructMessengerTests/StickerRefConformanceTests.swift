//
//  StickerRefConformanceTests.swift
//  ConstructMessengerTests
//
//  This client must decode a sticker reference and judge its validity the way every client
//  does. A reference one client accepts and another rejects is a bubble on one screen and
//  nothing on the other, and nothing reports it.
//
//  `construct-protos/conformance/knst_sticker_ref.json` is the authority, vendored into
//  Generated/ by ./generate_grpc_swift.sh. The vectors are protoc-encoded; the rules are the
//  numbers `StickerWireRules` must carry — the last test holds the two together.
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class StickerRefConformanceTests: XCTestCase {

    private struct Vector: Decodable {
        let id: String
        let packIdHex: String
        let index: UInt32
        let emoji: String
        let messageContentHex: String
        enum CodingKeys: String, CodingKey {
            case id, index, emoji
            case packIdHex = "pack_id_hex"
            case messageContentHex = "message_content_hex"
        }
    }
    private struct Rules: Decodable {
        let packIdBytes: Int
        let emojiMinBytes: Int
        let emojiMaxBytes: Int
        enum CodingKeys: String, CodingKey {
            case packIdBytes = "pack_id_bytes"
            case emojiMinBytes = "emoji_min_bytes"
            case emojiMaxBytes = "emoji_max_bytes"
        }
    }
    private struct Case: Decodable {
        let packIdHex: String
        let emoji: String
        let valid: Bool
        let why: String?
        enum CodingKeys: String, CodingKey {
            case emoji, valid, why
            case packIdHex = "pack_id_hex"
        }
    }
    private struct File: Decodable {
        let vectors: [Vector]
        let rules: Rules
        let cases: [Case]
    }

    private func load() throws -> File {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_sticker_ref.json")
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(file.vectors.count, 3, "vectors look truncated")
        XCTAssertGreaterThanOrEqual(file.cases.count, 6, "cases look truncated")
        return file
    }

    // MARK: - Decode

    /// Every vector decodes through the generated type into a valid `StickerReference` with
    /// exactly the fields the file states.
    func testVectorsDecodeToTheStatedReference() throws {
        for v in try load().vectors {
            let content = try Shared_Proto_Messaging_V1_MessageContent(serializedBytes: hex(v.messageContentHex))
            guard case .sticker(let wire)? = content.content else {
                XCTFail("\(v.id): oneof is not sticker"); continue
            }
            let ref = try XCTUnwrap(StickerReference(wire: wire), "\(v.id): a golden vector must validate")
            XCTAssertEqual(ref.pack.hex, v.packIdHex, v.id)
            XCTAssertEqual(ref.index, v.index, v.id)
            XCTAssertEqual(ref.emoji, v.emoji, v.id)
        }
    }

    /// Our encoder produces the vector's bytes exactly. Protobuf is not canonical in general,
    /// but for these three fields in order it is, and a stray field or a changed number would
    /// show here before it showed on a device.
    func testEncodingReproducesTheVectorBytes() throws {
        for v in try load().vectors {
            let ref = try XCTUnwrap(StickerReference(
                pack: try XCTUnwrap(StickerPackID(hex(v.packIdHex))),
                index: v.index,
                emoji: v.emoji
            ))
            var content = Shared_Proto_Messaging_V1_MessageContent()
            content.sticker = ref.wire
            XCTAssertEqual(try content.serializedData(), hex(v.messageContentHex), v.id)
        }
    }

    // MARK: - Validate

    /// The validator answers every case the way the file says.
    ///
    /// Mutation: count `emoji` in scalars instead of bytes — the ZWJ family (7 scalars, 25
    /// bytes) still passes but the nine-grin case (9 scalars, 36 bytes) stops failing.
    func testValidatorAgreesWithEveryCase() throws {
        for c in try load().cases {
            let wire = Shared_Proto_Messaging_V1_StickerRef.with {
                $0.packID = hex(c.packIdHex)
                $0.index = 0
                $0.emoji = c.emoji
            }
            XCTAssertEqual(
                StickerReference(wire: wire) != nil, c.valid,
                "case \(c.why ?? c.emoji): file says \(c.valid)"
            )
        }
    }

    /// The constants in code are the numbers in the file. A rule changed in the vault and the
    /// vectors without this client following reddens here.
    func testRuleConstantsMatchTheVectorFile() throws {
        let rules = try load().rules
        XCTAssertEqual(StickerWireRules.packIdBytes, rules.packIdBytes)
        XCTAssertEqual(StickerWireRules.emojiMinBytes, rules.emojiMinBytes)
        XCTAssertEqual(StickerWireRules.emojiMaxBytes, rules.emojiMaxBytes)
    }

    // MARK: - Helpers

    private func hex(_ s: String) -> Data {
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}
