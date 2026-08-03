//
//  FrameContentTypeTests.swift
//  ConstructMessengerTests
//
//  The KNST frame carries the content type in header byte 5, inside the ciphertext, so that the
//  precise type stops riding in `SealedInner.content_type` where the destination server reads it.
//  See decisions/sealed-content-type-inside-the-plaintext-frame.md.
//
//  Byte 5 was `flags`: written 0x00 by `buildHeader` and never read by `parseChunk`, which stepped
//  from data[4] straight to data[6..22]. It was already on the wire in every framed message and
//  free, which is why the frame version stays 0x01.
//
//  Acceptance is mutation-based: write a constant into byte 5 instead of the argument, and
//  testContentTypeSurvivesTheFrame must go red.
//

import XCTest
@testable import Construct_Messenger

final class FrameContentTypeTests: XCTestCase {

    private func frames(_ plaintext: Data, contentType: UInt8) -> [Data] {
        ChunkedMessageCodec.encodeChunks(
            plaintext: plaintext, messageId: UUID(), contentType: contentType
        )
    }

    /// Every content type that can ride sealed must survive the round trip. 21 and 24 are here
    /// too: they keep a pre-decrypt hint on `SealedInner`, but the frame must still be able to
    /// carry them so the two can be cross-checked rather than silently disagreeing.
    func testContentTypeSurvivesTheFrame() throws {
        for contentType: UInt8 in [0, 1, 12, 13, 14, 21, 23, 24, 25, 26] {
            let payload = Data(repeating: 0x5A, count: 64)
            let framed = frames(payload, contentType: contentType)
            XCTAssertEqual(framed.count, 1)

            let parsed = try XCTUnwrap(ChunkedMessageCodec.parseChunk(data: framed[0]),
                                       "ct=\(contentType) must parse")
            XCTAssertEqual(parsed.contentType, contentType, "ct=\(contentType) must round-trip")
            XCTAssertEqual(parsed.payload, payload, "ct=\(contentType) payload must be intact")
        }
    }

    /// Multi-chunk: every chunk carries the type, so a reassembler can trust the first one it
    /// sees and a lost first chunk cannot leave the message untyped.
    func testEveryChunkCarriesTheType() throws {
        let big = Data(repeating: 0x11, count: ChunkedDeliveryConfig.chunkPayloadSize * 3 + 7)
        let framed = frames(big, contentType: 14)
        XCTAssertGreaterThan(framed.count, 1, "payload must actually span several chunks")

        for (index, chunk) in framed.enumerated() {
            let parsed = try XCTUnwrap(ChunkedMessageCodec.parseChunk(data: chunk))
            XCTAssertEqual(parsed.contentType, 14, "chunk \(index) must carry the type")
        }
    }

    /// The byte must not disturb anything else in the header.
    func testHeaderFieldsUnaffectedByTheType() throws {
        let payload = Data(repeating: 0x77, count: 100)
        let id = UUID()
        let a = try XCTUnwrap(ChunkedMessageCodec.parseChunk(
            data: ChunkedMessageCodec.encodeChunks(plaintext: payload, messageId: id, contentType: 0)[0]
        ))
        let b = try XCTUnwrap(ChunkedMessageCodec.parseChunk(
            data: ChunkedMessageCodec.encodeChunks(plaintext: payload, messageId: id, contentType: 26)[0]
        ))

        XCTAssertEqual(a.messageId, b.messageId)
        XCTAssertEqual(a.chunkIndex, b.chunkIndex)
        XCTAssertEqual(a.totalChunks, b.totalChunks)
        XCTAssertEqual(a.plaintextLength, b.plaintextLength)
        XCTAssertEqual(a.payload, b.payload)
        XCTAssertNotEqual(a.contentType, b.contentType)
    }

    /// The frame version is unchanged on purpose: no reader ever interpreted byte 5, so putting
    /// a type there cannot confuse anything that came before.
    func testFrameVersionIsUnchanged() {
        let framed = frames(Data([0x01]), contentType: 12)
        XCTAssertEqual(framed[0][4], ChunkedDeliveryConfig.version)
        XCTAssertEqual(ChunkedDeliveryConfig.version, 0x01)
        XCTAssertEqual(framed[0][5], 12, "byte 5 is the type")
    }
}
