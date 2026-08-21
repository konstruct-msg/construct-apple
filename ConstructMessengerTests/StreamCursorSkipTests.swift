//
//  StreamCursorSkipTests.swift
//  Construct MessengerTests
//
//  The escape hatch from a cursor stall, and the invariant it deliberately breaks.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class StreamCursorSkipTests: XCTestCase {

    private var persisted: [String] = []

    private func makeTracker() -> StreamCursorTracker {
        persisted = []
        return StreamCursorTracker(persist: { [self] in persisted.append($0) })
    }

    /// The stall, reproduced: one entry at the head never resolves, everything behind it does,
    /// and the cursor cannot move. Three weeks of backlog on device, 2026-08-20.
    func testAnUnresolvedHeadHoldsEverythingBehindIt() {
        let tracker = makeTracker()
        tracker.track(messageId: "stuck", cursor: "1785495484579-0")
        tracker.track(messageId: "b", cursor: "1785495484580-0")
        tracker.track(messageId: "c", cursor: "1785495484581-0")

        tracker.report(messageId: "b", .durable)
        tracker.report(messageId: "c", .durable)

        XCTAssertEqual(persisted, [], "the head is unresolved, so nothing may be committed")
        XCTAssertEqual(tracker.headBlocker()?.messageId, "stuck")
    }

    /// The hatch: jump to the furthest entry the server has delivered.
    func testSkippingCommitsTheFurthestDeliveredCursor() {
        let tracker = makeTracker()
        tracker.track(messageId: "stuck", cursor: "1785495484579-0")
        tracker.track(messageId: "b", cursor: "1785495484580-0")
        tracker.track(messageId: "c", cursor: "1787250672657-0")

        let committed = tracker.skipHeldBacklog()

        XCTAssertEqual(committed, "1787250672657-0")
        XCTAssertEqual(persisted, ["1787250672657-0"])
        XCTAssertNil(tracker.headBlocker(), "nothing is held after a skip")
        XCTAssertEqual(tracker.inFlightCount, 0)
    }

    /// It must be inert when there is nothing stuck — a user pressing it on a healthy client
    /// should not move the cursor anywhere.
    func testSkippingWithNothingHeldDoesNothing() {
        let tracker = makeTracker()

        XCTAssertNil(tracker.skipHeldBacklog())
        XCTAssertEqual(persisted, [], "no entries means no cursor to force")
    }

    /// Resolved entries at the head are committed normally first, so a skip that follows must not
    /// walk the cursor *backwards* to an already-passed position.
    func testSkippingNeverMovesTheCursorBackwards() {
        let tracker = makeTracker()
        tracker.track(messageId: "a", cursor: "1785495484579-0")
        tracker.track(messageId: "stuck", cursor: "1785495484580-0")
        tracker.track(messageId: "c", cursor: "1785495484581-0")

        tracker.report(messageId: "a", .durable)          // commits …579
        XCTAssertEqual(persisted, ["1785495484579-0"])

        tracker.skipHeldBacklog()

        XCTAssertEqual(persisted.last, "1785495484581-0", "forward only")
    }

    /// After a skip the tracker is usable again: new entries track and commit as normal, rather
    /// than the hatch leaving it in a state where the next stall cannot even be observed.
    func testTheTrackerKeepsWorkingAfterASkip() {
        let tracker = makeTracker()
        tracker.track(messageId: "stuck", cursor: "1785495484579-0")
        tracker.skipHeldBacklog()

        tracker.track(messageId: "fresh", cursor: "1787250672700-0")
        tracker.report(messageId: "fresh", .durable)

        XCTAssertEqual(persisted.last, "1787250672700-0")
        XCTAssertNil(tracker.headBlocker())
    }

    /// A deferred entry is held, not resolved — the skip has to take those too, since a deferred
    /// entry with no owner is exactly what stalled the device.
    func testSkippingTakesDeferredEntriesAsWell() {
        let tracker = makeTracker()
        tracker.track(messageId: "queued", cursor: "1785495484579-0")
        tracker.report(messageId: "queued", .deferred)

        XCTAssertEqual(tracker.headBlocker()?.state, "deferred")
        XCTAssertEqual(tracker.skipHeldBacklog(), "1785495484579-0")
        XCTAssertEqual(tracker.inFlightCount, 0)
    }
}
