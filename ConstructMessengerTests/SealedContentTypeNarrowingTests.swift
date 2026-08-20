//
//  SealedContentTypeNarrowingTests.swift
//  ConstructMessengerTests
//
//  Call signal (12), delivery receipt (14) and ping/ready (25/26) stopped announcing themselves
//  on `SealedInner.content_type` on 2026-08-03. The type now rides in KNST header byte 5, inside
//  the ciphertext, so the destination server can no longer tell a receipt from a message body or
//  see that a call is being set up.
//
//  Two types deliberately stay on `SealedInner`, and that residue is not an oversight:
//  END_SESSION (21) carries no ciphertext to hide a frame in, and SESSION_RESET_INIT (24) is
//  wire-identical to an ordinary X3DH carrier, so the receiver must know before it decrypts.
//  `testOnlyPostDecryptOpsAreFramed` is what keeps someone from "finishing the job" and making
//  either one unroutable.
//
//  See decisions/sealed-content-type-inside-the-plaintext-frame.md.
//

import XCTest
@testable import Construct_Messenger

final class SealedContentTypeNarrowingTests: XCTestCase {

    /// Every type that moved off `SealedInner` must come back out of the frame intact — type and
    /// payload both. If byte 5 were written as a constant, this goes red.
    func testHiddenTypesRoundTripThroughTheFrame() throws {
        for contentType: UInt8 in [12, 14, 25, 26] {
            let payload = Data((0..<200).map { UInt8($0 % 251) })
            let framed = ChunkedMessageCodec.frameWhole(payload, contentType: contentType, messageId: UUID())

            let control = try XCTUnwrap(ChunkedMessageCodec.controlFrame(framed), "ct=\(contentType)")
            XCTAssertEqual(control.contentType, contentType, "ct=\(contentType) must survive")
            XCTAssertEqual(control.payload, payload, "ct=\(contentType) payload must be exact")
        }
    }

    /// A WebRTC offer's SDP can exceed `chunkPayloadSize`, and `sendCallSignalProto` sends exactly
    /// one message. `encodeChunks` would split it into frames that producer has no way to send —
    /// the call would simply never connect. `frameWhole` must stay whole at any size.
    func testFrameWholeStaysOneFrameAboveTheChunkSize() throws {
        let big = Data(repeating: 0x3C, count: ChunkedDeliveryConfig.chunkPayloadSize * 2 + 11)
        let framed = ChunkedMessageCodec.frameWhole(big, contentType: 12, messageId: UUID())

        XCTAssertEqual(framed.count, ChunkedDeliveryConfig.headerSize + big.count)
        let control = try XCTUnwrap(ChunkedMessageCodec.controlFrame(framed))
        XCTAssertEqual(control.contentType, 12)
        XCTAssertEqual(control.payload, big, "a large SDP must arrive whole")

        // And it really is a single frame, not a first chunk.
        let parsed = try XCTUnwrap(ChunkedMessageCodec.parseChunk(data: framed))
        XCTAssertEqual(parsed.totalChunks, 1)
    }

    /// `controlFrame` is the routing input, so anything it accepts gets routed as control.
    /// It must reject what is not exactly one whole frame: a multi-chunk body belongs to the
    /// reassembler, and unframed bytes are not ours to interpret.
    func testControlFrameRejectsNonControlBytes() {
        let rawProto = Data([0x0A, 0x24, 0x61, 0x62, 0x63])
        XCTAssertNil(ChunkedMessageCodec.controlFrame(rawProto), "unframed bytes are not a control frame")

        XCTAssertNil(ChunkedMessageCodec.controlFrame(Data()), "empty must not parse")
        XCTAssertNil(ChunkedMessageCodec.controlFrame(Data("__session_ping_x__".utf8)),
                     "a magic string is not a frame")

        let multi = ChunkedMessageCodec.encodeChunks(
            plaintext: Data(repeating: 0x09, count: ChunkedDeliveryConfig.chunkPayloadSize * 2),
            messageId: UUID(),
            contentType: 1
        )
        XCTAssertGreaterThan(multi.count, 1)
        XCTAssertNil(ChunkedMessageCodec.controlFrame(multi[0]),
                     "a first chunk of a chunked body must go to the reassembler, not control routing")

        // The adversarial shape the `totalChunks == 1` guard actually exists for: a frame that
        // claims several chunks but declares a length small enough to pass the bounds check. A
        // real multi-chunk frame can never look like this (its length exceeds one chunk), so
        // without the guard a crafted frame would be routed as control and its remaining chunks
        // would never reach the reassembler.
        XCTAssertNil(ChunkedMessageCodec.controlFrame(Self.handBuiltFrame(totalChunks: 3, plaintextLength: 4, contentType: 14)),
                     "a frame claiming more chunks than it carries must not be routed as control")
        XCTAssertNotNil(ChunkedMessageCodec.controlFrame(Self.handBuiltFrame(totalChunks: 1, plaintextLength: 4, contentType: 14)),
                        "the same bytes with totalChunks=1 must parse — otherwise the assertion above proves nothing")
    }

    /// Header written byte by byte, so the test pins the wire format rather than trusting the
    /// encoder it is checking. Payload is 8 bytes; `plaintextLength` is a parameter so a frame
    /// can lie about it.
    private static func handBuiltFrame(totalChunks: UInt16, plaintextLength: UInt32, contentType: UInt8) -> Data {
        var data = Data()
        data.append(contentsOf: ChunkedDeliveryConfig.magic)   // 0..3
        data.append(ChunkedDeliveryConfig.version)             // 4
        data.append(contentType)                               // 5
        data.append(contentsOf: [UInt8](repeating: 0xAB, count: 16))  // 6..21  messageId
        data.append(contentsOf: [0x00, 0x00])                  // 22..23 chunkIndex
        data.append(UInt8(totalChunks >> 8)); data.append(UInt8(totalChunks & 0xFF))  // 24..25
        for shift in stride(from: 24, through: 0, by: -8) {    // 26..29 plaintextLength
            data.append(UInt8((plaintextLength >> UInt32(shift)) & 0xFF))
        }
        data.append(contentsOf: [UInt8](repeating: 0x5E, count: 8))
        return data
    }

    /// Only ops that are acted on *after* decryption may be framed.
    ///
    /// END_SESSION and SESSION_RESET_INIT must return nil: framing either would hide it from the
    /// pre-decrypt dispatch it depends on — END_SESSION has no ciphertext, and an SRI cannot be
    /// distinguished from an ordinary X3DH carrier by its body.
    func testOnlyPostDecryptOpsAreFramed() {
        XCTAssertEqual(SessionControlCodec.frameContentType(for: .ping), 25)
        XCTAssertEqual(SessionControlCodec.frameContentType(for: .ready), 26)

        XCTAssertNil(SessionControlCodec.frameContentType(for: .end),
                     "END_SESSION must keep its pre-decrypt hint — it has no ciphertext to hide in")
        XCTAssertNil(SessionControlCodec.frameContentType(for: .resetInit),
                     "SESSION_RESET_INIT must keep its pre-decrypt hint — it looks like a plain X3DH carrier")
        XCTAssertNil(SessionControlCodec.frameContentType(for: .unspecified))
    }

    /// The framed type and the op table must agree, or a ping would be framed as 25 and then
    /// dispatched as something else on arrival. Same class of defect the frame exists to end.
    func testFramedTypeAgreesWithTheOpTable() {
        for op: SessionControlCodec.Op in [.ping, .ready] {
            let framed = try? XCTUnwrap(SessionControlCodec.frameContentType(for: op))
            XCTAssertEqual(SessionControlCodec.op(forContentType: Int(framed ?? 0)), op,
                           "\(op) must round-trip through the frame byte")
        }
    }
}
