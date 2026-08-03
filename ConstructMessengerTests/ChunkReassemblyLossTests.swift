//
//  ChunkReassemblyLossTests.swift
//  ConstructMessengerTests
//
//  Until 2026-08-03 the chunk logging was inverted: every *intermediate* chunk raised an ERROR
//  warning that a multi-chunk message might be lost, and the one place a message is actually lost
//  — `cleanupExpired` dropping a reassembly that never completed — logged nothing and counted
//  nothing. A twelve-chunk photo that arrived perfectly produced eleven alarms; a real loss
//  produced none.
//
//  These tests pin the corrected direction. There was no test before because the event was
//  unobservable: `cleanupExpired` was private and read `Date()` directly, so nothing could reach
//  it without waiting out the 60s timeout. `now` is a parameter for exactly that reason.
//
//  Each test uses its own reassembler, never `.shared` — partial state in a singleton is how a
//  suite starts passing for reasons that have nothing to do with it.
//

import XCTest
@testable import Construct_Messenger

final class ChunkReassemblyLossTests: XCTestCase {

    /// Two chunks of one message, delivered one at a time.
    ///
    /// The payload is readable text on purpose: random bytes reassemble correctly and then decode
    /// to nothing, so a test asserting on the decoded result would fail for a reason that has
    /// nothing to do with reassembly. Text lets the survival test compare what came back.
    private func twoChunkMessage() -> (id: UUID, chunks: [Data], text: String) {
        let id = UUID()
        let text = String(repeating: "the quick brown fox. ", count: 200)
        XCTAssertGreaterThan(text.utf8.count, ChunkedDeliveryConfig.chunkPayloadSize,
                             "fixture must exceed one chunk or it proves nothing")
        let chunks = ChunkedMessageCodec.encodeChunks(
            plaintext: Data(text.utf8), messageId: id, contentType: 1
        )
        return (id, chunks, text)
    }

    /// An expired reassembly must be counted. This is the event the metric is named for, and the
    /// event that previously produced no record of any kind.
    func testExpiredReassemblyIsCounted() throws {
        let reassembler = ChunkedMessageReassembler()
        let message = twoChunkMessage()
        XCTAssertEqual(message.chunks.count, 2, "fixture must actually span two chunks")

        let before = PerformanceMetrics.shared.count(event: .chunkReassemblyExpired)

        guard case .incomplete = reassembler.process(data: message.chunks[0]) else {
            return XCTFail("first chunk of two must be incomplete")
        }
        XCTAssertEqual(PerformanceMetrics.shared.count(event: .chunkReassemblyExpired), before,
                       "an intermediate chunk is not a loss and must not be counted as one")

        reassembler.cleanupExpired(now: Date().addingTimeInterval(ChunkedDeliveryConfig.reassemblyTimeout + 1))

        XCTAssertEqual(PerformanceMetrics.shared.count(event: .chunkReassemblyExpired), before + 1,
                       "dropping an incomplete reassembly is the loss — it must be counted")
    }

    /// Expiry really discards the partial state. If it did not, the metric would be a lie: the
    /// message would still assemble and nothing would have been lost.
    func testExpiryDiscardsPartialState() throws {
        let reassembler = ChunkedMessageReassembler()
        let message = twoChunkMessage()

        _ = reassembler.process(data: message.chunks[0])
        reassembler.cleanupExpired(now: Date().addingTimeInterval(ChunkedDeliveryConfig.reassemblyTimeout + 1))

        guard case .incomplete = reassembler.process(data: message.chunks[1]) else {
            return XCTFail("after expiry the surviving chunk must not complete a message — the first one is gone")
        }
    }

    /// The sweep must leave a reassembly that is still within its window alone, or a slow
    /// multi-chunk photo would be destroyed by ordinary traffic arriving from another peer.
    func testFreshReassemblySurvivesTheSweep() throws {
        let reassembler = ChunkedMessageReassembler()
        let message = twoChunkMessage()

        _ = reassembler.process(data: message.chunks[0])
        reassembler.cleanupExpired(now: Date().addingTimeInterval(ChunkedDeliveryConfig.reassemblyTimeout - 5))

        switch reassembler.process(data: message.chunks[1]) {
        case .assembled(let text, _, _, _, _):
            XCTAssertEqual(text, message.text, "both halves must be rejoined, in order and intact")
        default:
            XCTFail("a reassembly inside its window must survive the sweep and complete")
        }
    }

    /// Ordinary traffic drives the sweep. The sweep used to live inside the chunked path, so a
    /// stalled reassembly stayed unreported unless another *chunked* message happened to arrive.
    /// It now runs at the top of `process`, which means any decrypted message from any peer —
    /// here a plain unframed one — is enough to surface the loss.
    func testAnyDecryptedMessageDrivesTheSweep() throws {
        let reassembler = ChunkedMessageReassembler()
        let message = twoChunkMessage()
        let before = PerformanceMetrics.shared.count(event: .chunkReassemblyExpired)

        _ = reassembler.process(data: message.chunks[0])
        XCTAssertEqual(PerformanceMetrics.shared.count(event: .chunkReassemblyExpired), before,
                       "nothing has expired yet")

        // A plain unframed message — not a chunk of anything — arriving after the window closed.
        _ = reassembler.process(
            data: Data("hello".utf8),
            now: Date().addingTimeInterval(ChunkedDeliveryConfig.reassemblyTimeout + 1)
        )

        XCTAssertEqual(PerformanceMetrics.shared.count(event: .chunkReassemblyExpired), before + 1,
                       "an unrelated message must still surface the stalled reassembly")
    }
}
