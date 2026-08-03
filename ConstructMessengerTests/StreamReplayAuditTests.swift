//
//  StreamReplayAuditTests.swift
//  ConstructMessengerTests
//
//  The audit exists to tell two causes of redelivery apart — the server ignoring `since_cursor`
//  versus our own cursor stalling — and it does that by ordering Redis stream ids. If the ordering
//  is wrong the audit does not merely go quiet, it accuses the wrong side, which is worse than no
//  diagnostic at all. These tests pin the two ways it could be wrong: naive string comparison, and
//  treating the boundary entry of an inclusive resume as a replay.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class StreamReplayAuditTests: XCTestCase {

    /// Lexicographic comparison gets this backwards: `"9999999999999"` sorts after
    /// `"10000000000000"` as text, and Redis ids are not zero-padded. Getting it backwards would
    /// report every ordinary new message as a below-cursor replay.
    func testOrderIsNumericNotLexicographic() {
        XCTAssertEqual(StreamReplayAudit.compare("10000000000000-0", "9999999999999-0"), .descending,
                       "a larger millisecond value is later in time regardless of string length")
        XCTAssertEqual(StreamReplayAudit.compare("9999999999999-0", "10000000000000-0"), .ascending)
    }

    /// Within one millisecond the sequence number decides, and it is not padded either.
    func testSequenceBreaksTiesNumerically() {
        XCTAssertEqual(StreamReplayAudit.compare("1785773624-10", "1785773624-9"), .descending,
                       "seq 10 follows seq 9 — as text it would precede it")
        XCTAssertEqual(StreamReplayAudit.compare("1785773624-2", "1785773624-2"), .same)
    }

    /// An id shape we do not recognise must produce no verdict. Guessing here would mean logging a
    /// server fault on the strength of a parse we know failed.
    func testUnknownShapeYieldsNoVerdict() {
        XCTAssertNil(StreamReplayAudit.compare("not-a-cursor", "1785773624-0"))
        XCTAssertNil(StreamReplayAudit.compare("1785773624-0", "1785773624"))
        XCTAssertNil(StreamReplayAudit.compare("", "1785773624-0"))
    }

    /// The entry at exactly the subscribed cursor is an inclusive resume — one duplicate, bounded,
    /// harmless. It is `.same`, never `.ascending`, so the audit counts it apart from the replay
    /// it would otherwise be mistaken for.
    func testBoundaryEntryIsNotBelowTheCursor() {
        XCTAssertEqual(StreamReplayAudit.compare("1785773624-7", "1785773624-7"), .same,
                       "an off-by-one resume must not be reported as the server ignoring the cursor")
    }

    /// The stall this is meant to surface: a head entry that never resolves holds the committed
    /// cursor, so the server resends everything behind it on every reconnect. Before `headBlocker`
    /// the stall was real but nameless.
    func testHeadBlockerNamesTheEntryHoldingTheCursor() {
        let tracker = StreamCursorTracker(persist: { _ in })
        tracker.track(messageId: "a", cursor: "1785773624-1")
        tracker.track(messageId: "b", cursor: "1785773624-2")

        // `b` is durable but `a` is queued for session init — the cursor cannot pass `a`.
        tracker.report(messageId: "b", .durable)
        tracker.report(messageId: "a", .deferred)

        let blocker = tracker.headBlocker()
        XCTAssertEqual(blocker?.messageId, "a", "the head entry, not the resolved one behind it")
        XCTAssertEqual(blocker?.state, "deferred")
    }

    /// And once the head resolves there is no blocker to report — otherwise a healthy stream would
    /// log a stall on every connect and the signal would be worthless.
    func testNoBlockerWhenTheCursorIsFree() {
        let tracker = StreamCursorTracker(persist: { _ in })
        tracker.track(messageId: "a", cursor: "1785773624-1")
        tracker.report(messageId: "a", .durable)
        XCTAssertNil(tracker.headBlocker(), "a fully drained tracker is not stalled")
    }
}
