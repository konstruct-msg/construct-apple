import XCTest
@testable import Construct_Messenger

/// The KNST frame on iOS is the core's (core 0.31, TODO 94): this app splits, frames and parses
/// through `knst_encode_chunks` / `knst_frame_whole` / `knst_parse`, and the result is what
/// `construct-protos/conformance/knst_frame.json` says — the same bytes Android and the TUI make.
///
/// Until 2026-10-02 `ChunkedMessageCodec` wrote the 30-byte header itself, a third copy of a format
/// with no vectors. What stays in Swift are the two numbers other code budgets by
/// (`chunkPayloadSize`, `maxChunks`); they are pinned to the vectors here, so they cannot drift
/// from what the core splits by.
final class KnstFrameConformanceTests: XCTestCase {

    private func vectors() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_frame.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func hex(_ s: String) -> Data {
        var data = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            data.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    func testTheBudgetNumbersAreTheCoresSplit() throws {
        let v = try vectors()
        XCTAssertEqual(v["chunk_payload_size"] as? Int, ChunkedDeliveryConfig.chunkPayloadSize)
        XCTAssertEqual(v["max_chunks"] as? Int, Int(ChunkedDeliveryConfig.maxChunks))
    }

    func testEveryBodySplitsAsTheVectorsSay() throws {
        let v = try vectors()
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(v["message_id"] as? String)))
        let cases = try XCTUnwrap(v["encode"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 6, "vectors look truncated")
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let len = try XCTUnwrap(c["payload_len"] as? Int)
            let body = Data((0..<len).map { UInt8($0 % 251) })
            let ct = UInt8(try XCTUnwrap(c["content_type"] as? Int))
            let frames = ChunkedMessageCodec.encodeChunks(plaintext: body, messageId: id, contentType: ct)
            if let want = c["frames"] as? [String] {
                XCTAssertEqual(frames, want.map(hex), name)
            } else {
                XCTAssertTrue(frames.isEmpty, "\(name): refused, not truncated")
            }
        }
    }

    func testEveryFrameReadsAsTheVectorsSay() throws {
        let cases = try XCTUnwrap(try vectors()["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 9, "vectors look truncated")
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let bytes = hex(try XCTUnwrap(c["frame"] as? String))
            let parsed = ChunkedMessageCodec.parseChunk(data: bytes)
            XCTAssertEqual(parsed != nil, c["is_frame"] as? Bool, "\(name): is_frame")
            guard let parsed else { continue }
            XCTAssertEqual(Int(parsed.contentType), c["content_type"] as? Int, name)
            XCTAssertEqual(parsed.messageId.uuidString.lowercased(), c["message_id"] as? String, name)
            let control = ChunkedMessageCodec.controlFrame(bytes)
            XCTAssertEqual(control != nil, c["control"] as? Bool, "\(name): control")
            if let body = c["body"] as? String {
                XCTAssertEqual(control?.payload, hex(body), "\(name): body")
            }
        }
    }
}
