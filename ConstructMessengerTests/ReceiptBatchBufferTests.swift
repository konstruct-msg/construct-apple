//
//  ReceiptBatchBufferTests.swift
//  Construct MessengerTests
//
//  The accumulation, without the timer. Every case here is a shape the 2026-08-19 device logs
//  actually produced.
//

import XCTest
@testable import Construct_Messenger

final class ReceiptBatchBufferTests: XCTestCase {

    private let alice = "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"
    private let bob = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

    // MARK: - The defect

    /// The measurement this exists for. 549 receipts left the device in 15 seconds, one per
    /// replayed message, each a full encrypt + ratchet advance + RPC + ~2 KB keychain write.
    /// The same information is 549 ids in 9 receipts.
    func testAReplayBurstCollapsesIntoAHandfulOfReceipts() {
        var buffer = ReceiptBatchBuffer()
        for i in 0..<549 { buffer.add(messageId: "msg-\(i)", to: alice) }

        let receipts = buffer.drain()

        XCTAssertEqual(receipts.count, 9, "549 ids at 64 per receipt")
        XCTAssertEqual(receipts.reduce(0) { $0 + $1.messageIds.count }, 549, "no id may be lost")
        XCTAssertEqual(Set(receipts.flatMap(\.messageIds)).count, 549, "and none duplicated")
        XCTAssertTrue(receipts.allSatisfy { $0.contactId == alice })
    }

    /// A single message must still produce a single receipt with a single id. The batcher may not
    /// buy the storm case by making the ordinary case worse.
    func testOneMessageIsOneReceipt() {
        var buffer = ReceiptBatchBuffer()
        buffer.add(messageId: "msg-1", to: alice)

        let receipts = buffer.drain()

        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].contactId, alice)
        XCTAssertEqual(receipts[0].messageIds, ["msg-1"])
    }

    // MARK: - Separation

    /// Both peers replay at once — the run that produced this had 4211 dispatches split across two
    /// contacts. A receipt is addressed, so ids may never cross between them: telling Alice that
    /// Bob's message arrived is both wrong and a disclosure.
    func testIdsNeverCrossBetweenContacts() {
        var buffer = ReceiptBatchBuffer()
        buffer.add(messageId: "a-1", to: alice)
        buffer.add(messageId: "b-1", to: bob)
        buffer.add(messageId: "a-2", to: alice)

        let receipts = buffer.drain()

        XCTAssertEqual(receipts.count, 2)
        let byContact = Dictionary(uniqueKeysWithValues: receipts.map { ($0.contactId, $0.messageIds) })
        XCTAssertEqual(byContact[alice], ["a-1", "a-2"])
        XCTAssertEqual(byContact[bob], ["b-1"])
    }

    /// The chunk ceiling is per receipt, not per contact: two contacts over the limit produce two
    /// runs of chunks, not one interleaved run.
    func testEachContactIsChunkedOnItsOwn() {
        var buffer = ReceiptBatchBuffer()
        for i in 0..<70 { buffer.add(messageId: "a-\(i)", to: alice) }
        for i in 0..<70 { buffer.add(messageId: "b-\(i)", to: bob) }

        let receipts = buffer.drain()

        XCTAssertEqual(receipts.count, 4)
        XCTAssertEqual(receipts.filter { $0.contactId == alice }.map(\.messageIds.count), [64, 6])
        XCTAssertEqual(receipts.filter { $0.contactId == bob }.map(\.messageIds.count), [64, 6])
    }

    // MARK: - Duplicates

    /// The same id arriving twice inside one window is the storm, not a second obligation — the
    /// throttle already ruled this id due exactly once. Sending it twice in the same receipt would
    /// hand the peer a list it has to dedupe.
    func testTheSameIdTwiceInOneWindowIsOneEntry() {
        var buffer = ReceiptBatchBuffer()
        buffer.add(messageId: "msg-1", to: alice)
        buffer.add(messageId: "msg-1", to: alice)
        buffer.add(messageId: "msg-2", to: alice)
        buffer.add(messageId: "msg-1", to: alice)

        XCTAssertEqual(buffer.drain().map(\.messageIds), [["msg-1", "msg-2"]])
    }

    /// Dedupe is scoped to the contact. The same message id owed to two peers is two receipts —
    /// only a multi-device fan-out produces this, and collapsing it would drop one.
    func testTheSameIdToTwoContactsIsTwoEntries() {
        var buffer = ReceiptBatchBuffer()
        buffer.add(messageId: "msg-1", to: alice)
        buffer.add(messageId: "msg-1", to: bob)

        let receipts = buffer.drain()

        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(receipts.allSatisfy { $0.messageIds == ["msg-1"] })
    }

    // MARK: - Draining

    /// Draining empties. A second flush firing behind the first must not re-send what already went
    /// out — that is the amplifier this whole file removes, rebuilt one layer up.
    func testDrainingLeavesNothingBehind() {
        var buffer = ReceiptBatchBuffer()
        buffer.add(messageId: "msg-1", to: alice)

        XCTAssertEqual(buffer.drain().count, 1)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.drain().count, 0, "a second drain owes nothing")
    }

    /// And an id arriving after a drain is owed again — the dedupe is per window, not forever.
    /// Permanence is `ReceiptResendThrottle`'s job and it holds a 10-minute window for it.
    func testAnIdArrivingAfterADrainIsOwedAgain() {
        var buffer = ReceiptBatchBuffer()
        buffer.add(messageId: "msg-1", to: alice)
        _ = buffer.drain()
        buffer.add(messageId: "msg-1", to: alice)

        XCTAssertEqual(buffer.drain().map(\.messageIds), [["msg-1"]])
    }

    func testAnEmptyBufferSendsNothing() {
        var buffer = ReceiptBatchBuffer()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    /// Exactly at the ceiling is one receipt, not one plus an empty one.
    func testExactlyTheCeilingIsASingleReceipt() {
        var buffer = ReceiptBatchBuffer()
        for i in 0..<ReceiptBatchBuffer.maxIdsPerReceipt { buffer.add(messageId: "msg-\(i)", to: alice) }

        let receipts = buffer.drain()

        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].messageIds.count, ReceiptBatchBuffer.maxIdsPerReceipt)
    }
}
