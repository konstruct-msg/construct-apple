//
//  StreamCursorTrackerTests.swift
//  ConstructMessengerTests
//
//  Regression lock for the offline-delivery cursor-after-persist window: the resume cursor
//  must never advance past a message that is not yet durably handled (see StreamCursorTracker).
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class StreamCursorTrackerTests: XCTestCase {

    /// Builds a tracker that records every committed cursor into `saved`.
    private func makeTracker() -> (StreamCursorTracker, () -> [String]) {
        var saved: [String] = []
        let tracker = StreamCursorTracker(persist: { saved.append($0) })
        return (tracker, { saved })
    }

    func testInOrderResolveAdvancesEachStep() {
        let (t, saved) = makeTracker()
        t.track(messageId: "a", cursor: "1-0")
        t.track(messageId: "b", cursor: "2-0")
        t.track(messageId: "c", cursor: "3-0")

        t.resolve(messageId: "a")
        t.resolve(messageId: "b")
        t.resolve(messageId: "c")

        XCTAssertEqual(saved(), ["1-0", "2-0", "3-0"])
        XCTAssertEqual(t.inFlightCount, 0)
    }

    func testOutOfOrderResolveBlocksUntilContiguous() {
        let (t, saved) = makeTracker()
        t.track(messageId: "a", cursor: "1-0")
        t.track(messageId: "b", cursor: "2-0")
        t.track(messageId: "c", cursor: "3-0")

        // Resolve later entries first — the head ("a") is still pending, so nothing commits.
        t.resolve(messageId: "c")
        t.resolve(messageId: "b")
        XCTAssertEqual(saved(), [])

        // Resolving the head releases the whole contiguous run at once.
        t.resolve(messageId: "a")
        XCTAssertEqual(saved(), ["3-0"])
        XCTAssertEqual(t.inFlightCount, 0)
    }

    func testDeferredMessageHoldsWatermark() {
        let (t, saved) = makeTracker()
        t.track(messageId: "a", cursor: "1-0")
        t.track(messageId: "b", cursor: "2-0")

        // "a" is queued for session init (deferred); "b" persisted durably.
        t.report(messageId: "a", .deferred)
        t.report(messageId: "b", .durable)
        // Must NOT advance: advancing to "b" would trim "a" off the server while it sits only
        // in the in-memory pending queue — the exact loss this guards against.
        XCTAssertEqual(saved(), [])

        // "a" drains and persists → the watermark jumps to "b".
        t.resolve(messageId: "a")
        XCTAssertEqual(saved(), ["2-0"])
    }

    /// The concrete bug: a deferred (no-session) message from sender A, then a durable message
    /// or receipt from sender B with a later cursor — the cursor must stay behind A.
    func testReceiptDoesNotLeapfrogDeferredMessage() {
        let (t, saved) = makeTracker()
        t.track(messageId: "msgA", cursor: "10-0")   // from A, no session yet
        t.report(messageId: "msgA", .deferred)

        // Receipt arrives next (tracked + resolved inline, cursor 11-0).
        t.track(messageId: "11-0", cursor: "11-0")
        t.resolve(messageId: "11-0")

        XCTAssertEqual(saved(), [], "receipt must not advance the cursor past the deferred msgA")

        t.resolve(messageId: "msgA")
        XCTAssertEqual(saved(), ["11-0"])
    }

    func testSkipLeavesEntryPending() {
        let (t, saved) = makeTracker()
        t.track(messageId: "a", cursor: "1-0")
        t.report(messageId: "a", .skip)
        XCTAssertEqual(saved(), [])
        XCTAssertEqual(t.inFlightCount, 1)

        // A later durable resolve of the same id (e.g. the owning in-flight path) advances it.
        t.resolve(messageId: "a")
        XCTAssertEqual(saved(), ["1-0"])
    }

    func testReportUntrackedIdIsNoOp() {
        let (t, saved) = makeTracker()
        XCTAssertNil(t.report(messageId: "ghost", .durable))
        XCTAssertNil(t.resolve(messageId: "ghost"))
        XCTAssertEqual(saved(), [])
        XCTAssertEqual(t.inFlightCount, 0)
    }

    func testDuplicateTrackKeepsSingleEntry() {
        let (t, saved) = makeTracker()
        t.track(messageId: "a", cursor: "1-0")
        t.track(messageId: "a", cursor: "9-0")  // duplicate id — ignored, keeps original cursor
        XCTAssertEqual(t.inFlightCount, 1)
        t.resolve(messageId: "a")
        XCTAssertEqual(saved(), ["1-0"])
    }

    func testEmptyInputsIgnored() {
        let (t, saved) = makeTracker()
        t.track(messageId: "", cursor: "1-0")
        t.track(messageId: "a", cursor: "")
        XCTAssertEqual(t.inFlightCount, 0)
        XCTAssertEqual(saved(), [])
    }

    func testResetClearsState() {
        let (t, saved) = makeTracker()
        t.track(messageId: "a", cursor: "1-0")
        t.reset()
        XCTAssertEqual(t.inFlightCount, 0)
        // Resolving after reset is a no-op (entry gone); cursor self-heals via re-delivery.
        t.resolve(messageId: "a")
        XCTAssertEqual(saved(), [])
    }

    func testCursorDoesNotRepersistSameValue() {
        let (t, saved) = makeTracker()
        t.track(messageId: "a", cursor: "1-0")
        t.resolve(messageId: "a")
        // Resolving an already-popped id must not re-persist.
        t.resolve(messageId: "a")
        XCTAssertEqual(saved(), ["1-0"])
    }
}
