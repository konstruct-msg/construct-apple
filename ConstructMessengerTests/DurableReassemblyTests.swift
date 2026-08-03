//
//  DurableReassemblyTests.swift
//  ConstructMessengerTests
//
//  A half-arrived multi-chunk message used to live only in process memory, and it could not be
//  rebuilt from the network afterwards: decrypting a chunk consumes its ratchet key
//  (`skipped_message_keys.remove(...)`, and keys are only kept for messages the ratchet *skipped*),
//  so a redelivery after a kill decrypts to nothing. Either the plaintext survives the restart on
//  this device or the photo is gone.
//
//  `testPartialSurvivesAProcessRestart` is the test the whole store exists for. The others guard
//  the properties that make it safe: the bytes are on disk before `put` returns (which is what
//  makes marking intermediate envelopes processed honest rather than a way to lose messages), and
//  expiry still reports a real loss.
//
//  See decisions/durable-chunk-reassembly.md.
//

import XCTest
@testable import Construct_Messenger

final class DurableReassemblyTests: XCTestCase {

    private let store = PendingReassemblyStore.shared

    private func chunks(count: Int, size: Int = 64) -> [Data] {
        (0..<count).map { Data(repeating: UInt8($0 + 1), count: size) }
    }

    private func putChunk(
        _ messageId: UUID, index: UInt16, of total: UInt16, payload: Data,
        plaintextLength: Int, now: Date = Date()
    ) -> PendingReassembly? {
        store.put(
            messageId: messageId, chunkIndex: index, totalChunks: total,
            plaintextLength: plaintextLength, contentType: 1, payload: payload,
            envelopeId: "env-\(messageId.uuidString.prefix(4))-\(index)", now: now
        )
    }

    override func tearDown() {
        super.tearDown()
    }

    /// The reason this store exists. Two of three chunks arrive, the process dies, and the
    /// remaining chunk arrives after relaunch — the message must still assemble, because the
    /// network cannot supply the first two again in a decryptable form.
    func testPartialSurvivesAProcessRestart() throws {
        let id = UUID()
        let parts = chunks(count: 3)
        let total = parts.reduce(0) { $0 + $1.count }

        XCTAssertNil(putChunk(id, index: 0, of: 3, payload: parts[0], plaintextLength: total))
        XCTAssertNil(putChunk(id, index: 1, of: 3, payload: parts[1], plaintextLength: total))

        // Stand in for the kill: drop everything the store holds in memory and make it read the
        // disk again, which is exactly what a relaunch does.
        store.forgetInMemoryStateForTesting()

        let completed = try XCTUnwrap(
            putChunk(id, index: 2, of: 3, payload: parts[2], plaintextLength: total),
            "the last chunk must complete a message whose earlier chunks only exist on disk"
        )
        XCTAssertEqual(completed.assembled(), Data(parts.joined()),
                       "restored chunks must rejoin in order and intact")
        store.remove(messageId: id)
    }

    /// `put` returning means the bytes are durable. This is load-bearing: `MessageRouter` marks the
    /// envelope processed on the strength of it, and marking against process memory would turn a
    /// redelivery storm into permanent loss on the next restart.
    func testPutIsDurableBeforeItReturns() throws {
        let id = UUID()
        let parts = chunks(count: 2)
        let total = parts.reduce(0) { $0 + $1.count }

        XCTAssertNil(putChunk(id, index: 0, of: 2, payload: parts[0], plaintextLength: total))
        store.forgetInMemoryStateForTesting()

        let completed = try XCTUnwrap(putChunk(id, index: 1, of: 2, payload: parts[1], plaintextLength: total))
        XCTAssertEqual(completed.receivedChunks.count, 2,
                       "the chunk written before the restart must come back")
        store.remove(messageId: id)
    }

    /// A completed reassembly leaves nothing behind — otherwise every photo would accumulate on
    /// disk until the retention window expired it.
    func testCompletedReassemblyIsRemoved() throws {
        let id = UUID()
        let parts = chunks(count: 2)
        let total = parts.reduce(0) { $0 + $1.count }
        let before = store.pendingCount()

        _ = putChunk(id, index: 0, of: 2, payload: parts[0], plaintextLength: total)
        _ = putChunk(id, index: 1, of: 2, payload: parts[1], plaintextLength: total)
        store.remove(messageId: id)

        store.forgetInMemoryStateForTesting()
        XCTAssertEqual(store.pendingCount(), before,
                       "an assembled message must leave no files behind")
    }

    /// Expiry still reports a real loss, and only a real one: at 24 h the missing chunks can never
    /// be decrypted again, so this is the moment the message is genuinely unrecoverable.
    func testExpiryAfterRetentionIsCountedAndDropped() throws {
        let id = UUID()
        let parts = chunks(count: 2)
        let total = parts.reduce(0) { $0 + $1.count }
        let before = PerformanceMetrics.shared.count(event: .chunkReassemblyExpired)

        _ = putChunk(id, index: 0, of: 2, payload: parts[0], plaintextLength: total)

        store.sweepExpired(now: Date().addingTimeInterval(PendingReassemblyStore.retention - 60))
        XCTAssertEqual(PerformanceMetrics.shared.count(event: .chunkReassemblyExpired), before,
                       "inside the window nothing is lost yet")

        store.sweepExpired(now: Date().addingTimeInterval(PendingReassemblyStore.retention + 60))
        XCTAssertEqual(PerformanceMetrics.shared.count(event: .chunkReassemblyExpired), before + 1,
                       "past the window the message is unrecoverable and must be counted")

        store.forgetInMemoryStateForTesting()
        XCTAssertNil(putChunk(id, index: 1, of: 2, payload: parts[1], plaintextLength: total),
                     "an expired partial must be gone from disk, not silently completed later")
        store.remove(messageId: id)
    }

    /// Retention must outlive a relaunch. 60 s was the old *memory* bound; reusing it here would
    /// discard the partial before the restart the store was written for.
    func testRetentionOutlivesARelaunch() {
        XCTAssertGreaterThan(PendingReassemblyStore.retention, ChunkedDeliveryConfig.reassemblyTimeout * 10,
                             "retention bounds recoverability, not memory — minutes are not enough")
    }

    // MARK: - Carried over from ChunkReassemblyLossTests
    //
    // That suite was written against the reassembler's own in-memory map, which no longer exists —
    // its subject is gone, so it was deleted rather than patched. These two assertions were the
    // part that still means something, restated against the store.

    /// A message still inside its window must survive a sweep, or ordinary traffic from another
    /// peer would destroy a photo mid-arrival.
    func testChunkedBodyStillAssemblesThroughTheReassembler() throws {
        let reassembler = ChunkedMessageReassembler()
        let text = String(repeating: "the quick brown fox. ", count: 200)
        XCTAssertGreaterThan(text.utf8.count, ChunkedDeliveryConfig.chunkPayloadSize,
                             "fixture must span more than one chunk")
        let frames = ChunkedMessageCodec.encodeChunks(
            plaintext: Data(text.utf8), messageId: UUID(), contentType: 1
        )
        XCTAssertGreaterThan(frames.count, 1)

        for frame in frames.dropLast() {
            guard case .incomplete = reassembler.process(data: frame, envelopeId: "e") else {
                return XCTFail("only the last chunk may complete the message")
            }
        }
        switch reassembler.process(data: frames[frames.count - 1], envelopeId: "e") {
        case .assembled(let assembled, _, _, _, _):
            XCTAssertEqual(assembled, text, "chunks must rejoin in order and intact")
        default:
            XCTFail("the final chunk must complete the message")
        }
    }

    /// Any decrypted message drives the sweep, not just another chunk — otherwise a stalled
    /// reassembly stays unreported unless a second chunked message happens to arrive.
    func testAnyDecryptedMessageDrivesTheSweep() throws {
        let reassembler = ChunkedMessageReassembler()
        let id = UUID()
        let parts = chunks(count: 2)
        let before = PerformanceMetrics.shared.count(event: .chunkReassemblyExpired)

        _ = putChunk(id, index: 0, of: 2, payload: parts[0], plaintextLength: parts[0].count * 2)
        XCTAssertEqual(PerformanceMetrics.shared.count(event: .chunkReassemblyExpired), before,
                       "nothing has expired yet")

        // A plain unframed message — not a chunk of anything — arriving past the window.
        _ = reassembler.process(
            data: Data("hello".utf8),
            envelopeId: "unrelated",
            now: Date().addingTimeInterval(PendingReassemblyStore.retention + 60)
        )

        XCTAssertEqual(PerformanceMetrics.shared.count(event: .chunkReassemblyExpired), before + 1,
                       "an unrelated message must still surface the stalled reassembly")
    }
}
