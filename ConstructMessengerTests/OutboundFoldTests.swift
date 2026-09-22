//
//  OutboundFoldTests.swift
//  ConstructMessengerTests
//
//  The row has one status and the person has N devices. This is the rule that relates them,
//  held to what it promises rather than to what a run happened to produce.
//

import XCTest
@testable import Construct_Messenger

final class OutboundFoldTests: XCTestCase {

    private let base = "34f009c9-caa1-41a3-964e-40af9f3129a7"

    private func response(_ status: String, retryable: Bool = true, errorCode: String = "",
                          retryAfterMs: Int64 = 0, order: (ts: Int64, seq: UInt64)? = nil) -> SendMessageResponse {
        SendMessageResponse(
            messageId: base, status: status,
            messageNumber: order?.seq ?? 0, serverTimestamp: order?.ts ?? 0,
            retryable: retryable, errorCode: errorCode, retryAfterMs: retryAfterMs
        )
    }

    private struct Boom: Error {}

    // MARK: - At least one device accepted

    /// The message is in the mailbox, so the row says sent; the device that was not reached is
    /// owed, not the row's problem. Mutation: require every device — the status turns `failed`
    /// and this reddens.
    func testOneAcceptedDeviceMakesTheRowSentAndTheRestOwed() {
        let report = OutboundMessagePipeline.fold([
            .init(deviceId: "a", response: response("sent"), error: nil),
            .init(deviceId: "b", response: nil, error: Boom()),
            .init(deviceId: "c", response: response("failed", retryable: true, errorCode: "rate_limit"), error: nil)
        ], baseMessageId: base)
        XCTAssertEqual(report.status.status, "sent")
        XCTAssertEqual(report.accepted, ["a"])
        XCTAssertEqual(report.owed, ["b", "c"])
        XCTAssertEqual(report.status.errorCode, "", "a device's refusal is not the row's error")
        XCTAssertEqual(report.status.retryAfterMs, 0)
    }

    /// A refusal that is final for one device is a loss, not a debt: retrying it forever would
    /// spend a token per attempt on a device that will never take it.
    func testAFinalRefusalOnOneDeviceIsNotOwed() {
        let report = OutboundMessagePipeline.fold([
            .init(deviceId: "a", response: response("sent"), error: nil),
            .init(deviceId: "b", response: response("failed", retryable: false, errorCode: "encryptionFailed"), error: nil)
        ], baseMessageId: base)
        XCTAssertEqual(report.status.status, "sent")
        XCTAssertEqual(report.owed, [])
    }

    /// The server order the row is placed by comes from an accepted copy — the earliest — never
    /// from a refusal, which carries none.
    func testTheRowTakesTheEarliestAcceptedServerOrder() {
        let report = OutboundMessagePipeline.fold([
            .init(deviceId: "a", response: response("sent", order: (ts: 2_000, seq: 7)), error: nil),
            .init(deviceId: "b", response: response("sent", order: (ts: 1_000, seq: 3)), error: nil)
        ], baseMessageId: base)
        XCTAssertEqual(report.status.serverTimestamp, 1_000)
        XCTAssertEqual(report.status.messageNumber, 3)
        XCTAssertEqual(report.owed, [])
    }

    // MARK: - No device accepted

    /// Nothing went: the worst answer is the row's, with the longest wait and the first code, so a
    /// rate-limited message reschedules by the hint rather than hammering.
    func testNothingAcceptedFoldsTheWorstAnswer() {
        let report = OutboundMessagePipeline.fold([
            .init(deviceId: "a", response: response("queued", retryAfterMs: 500), error: nil),
            .init(deviceId: "b", response: response("failed", retryable: true, errorCode: "rate_limit", retryAfterMs: 3_000), error: nil)
        ], baseMessageId: base)
        XCTAssertEqual(report.status.status, "failed")
        XCTAssertTrue(report.status.retryable)
        XCTAssertEqual(report.status.errorCode, "rate_limit")
        XCTAssertEqual(report.status.retryAfterMs, 3_000)
        XCTAssertEqual(report.owed, ["a", "b"])
        XCTAssertEqual(report.accepted, [])
    }

    /// Blocked is final on every device it names. Until 2026-09-22 the chunk fold had no case for
    /// it and a blocked send read as `sent` with `retryable == false` — the caller's `"blocked"`
    /// branch was unreachable.
    func testBlockedIsFinal() {
        let report = OutboundMessagePipeline.fold([
            .init(deviceId: "a", response: response("blocked", retryable: false, errorCode: "blocked"), error: nil)
        ], baseMessageId: base)
        XCTAssertEqual(report.status.status, "blocked")
        XCTAssertFalse(report.status.retryable)
        XCTAssertEqual(report.owed, [])
    }

    /// A device that threw has no server answer to fold; it is owed and nothing else.
    func testEveryDeviceThrowingLeavesEveryDeviceOwed() {
        let report = OutboundMessagePipeline.fold([
            .init(deviceId: "a", response: nil, error: Boom()),
            .init(deviceId: "b", response: nil, error: Boom())
        ], baseMessageId: base)
        XCTAssertEqual(report.accepted, [])
        XCTAssertEqual(report.owed, ["a", "b"])
        XCTAssertTrue(report.status.retryable)
    }

    // MARK: - One copy over its chunks

    /// One failed chunk fails the copy: a partial set never reassembles.
    func testOneFailedChunkFailsTheCopy() {
        let copy = RecipientSendReport.Copy(
            deviceId: "a",
            response: OutboundMessagePipeline.aggregate(
                responses: [response("sent"), response("failed", retryable: true, errorCode: "x")],
                baseMessageId: base
            ),
            error: nil
        )
        XCTAssertFalse(copy.accepted)
        XCTAssertEqual(copy.response?.errorCode, "x")
    }
}

/// The stored ciphertexts a retry re-sends, and the device each is bound to.
final class OutgoingWirePayloadStoreDeviceTests: XCTestCase {

    private let base = "d4c1e7f2-6f31-4d6c-9c58-6c1c0f7d2a11"

    override func tearDown() {
        OutgoingWirePayloadStore.shared.remove(baseMessageId: base)
        super.tearDown()
    }

    /// Each chunk comes back with the device it was encrypted for, chunk index first and wire id
    /// second — so a retry re-seals every copy to the right key and sends them in one order.
    ///
    /// Mutation: drop `devices` from `Entry` — every `recipientDeviceId` reads nil and this reddens.
    func testChunksRememberTheirDeviceAndComeBackInAFixedOrder() {
        let store = OutgoingWirePayloadStore.shared
        store.saveChunk(baseMessageId: base, chunkMessageId: "\(base)-fd-aaaa-c1", wirePayload: Data([1]), recipientDeviceId: "devA")
        store.saveChunk(baseMessageId: base, chunkMessageId: "\(base)-fd-bbbb", wirePayload: Data([2]), recipientDeviceId: "devB")
        store.saveChunk(baseMessageId: base, chunkMessageId: "\(base)-fd-aaaa", wirePayload: Data([3]), recipientDeviceId: "devA")
        store.saveChunk(baseMessageId: base, chunkMessageId: "\(base)-fd-bbbb-c1", wirePayload: Data([4]), recipientDeviceId: "devB")

        let chunks = store.loadChunks(baseMessageId: base) ?? []
        XCTAssertEqual(chunks.map(\.chunkMessageId), [
            "\(base)-fd-aaaa", "\(base)-fd-bbbb", "\(base)-fd-aaaa-c1", "\(base)-fd-bbbb-c1"
        ])
        XCTAssertEqual(chunks.map(\.recipientDeviceId), ["devA", "devB", "devA", "devB"])
        XCTAssertEqual(chunks.map { $0.wirePayload.first }, [3, 2, 1, 4])
    }

    /// A chunk stored without a device — the pre-2026-09-22 entry shape — still loads, with the
    /// device unknown rather than the entry refused. The retry then takes the pinned device,
    /// which is the only one that shape ever encrypted for.
    func testAChunkWithoutADeviceStillLoads() {
        let store = OutgoingWirePayloadStore.shared
        store.saveChunk(baseMessageId: base, chunkMessageId: base, wirePayload: Data([9]), recipientDeviceId: nil)
        let chunks = store.loadChunks(baseMessageId: base) ?? []
        XCTAssertEqual(chunks.count, 1)
        XCTAssertNil(chunks.first?.recipientDeviceId)
        XCTAssertEqual(chunks.first?.wirePayload, Data([9]))
    }
}
