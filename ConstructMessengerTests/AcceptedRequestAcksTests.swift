//
//  AcceptedRequestAcksTests.swift
//  ConstructMessengerTests
//
//  An accepted contact request, once made into a contact, is acknowledged so the server deletes
//  its row at once instead of keeping it for 30 days (TODO 157, 2026-10-17).
//

import XCTest
@testable import Construct_Messenger

final class AcceptedRequestAcksTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "AcceptedRequestAcksTests"

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Mutation: make `add` a no-op — nothing is ever acknowledged and the rows wait for the sweep.
    func testAContactMadeFromARequestIsQueuedOnce() {
        AcceptedRequestAcks.add("r1", in: defaults)
        AcceptedRequestAcks.add("r1", in: defaults)
        XCTAssertEqual(AcceptedRequestAcks.pending(in: defaults), ["r1"])
    }

    /// A poll whose answer was lost confirms nothing, so the next one carries the same ids.
    /// Mutation: clear the queue when the ids are read instead of on `confirm`.
    func testTheQueueEmptiesOnlyWhenAnAnswerArrives() {
        AcceptedRequestAcks.add("r1", in: defaults)
        let first = AcceptedRequestAcks.pending(in: defaults)
        XCTAssertEqual(AcceptedRequestAcks.pending(in: defaults), first, "still there before an answer")
        AcceptedRequestAcks.confirm(first, in: defaults)
        XCTAssertEqual(AcceptedRequestAcks.pending(in: defaults), [])
    }

    /// One added while a poll was in flight was not sent, so it stays for the next.
    /// Mutation: `confirm` clears everything.
    func testAnIdAddedDuringAPollStays() {
        AcceptedRequestAcks.add("r1", in: defaults)
        let sent = AcceptedRequestAcks.pending(in: defaults)
        AcceptedRequestAcks.add("r2", in: defaults)
        AcceptedRequestAcks.confirm(sent, in: defaults)
        XCTAssertEqual(AcceptedRequestAcks.pending(in: defaults), ["r2"])
    }

    /// The server honours `perPoll` ids per call; the rest wait their turn.
    func testAPollCarriesAtMostWhatTheServerHonours() {
        for i in 0..<(AcceptedRequestAcks.perPoll + 5) { AcceptedRequestAcks.add("r\(i)", in: defaults) }
        let first = AcceptedRequestAcks.pending(in: defaults)
        XCTAssertEqual(first.count, AcceptedRequestAcks.perPoll)
        AcceptedRequestAcks.confirm(first, in: defaults)
        XCTAssertEqual(AcceptedRequestAcks.pending(in: defaults).count, 5)
    }
}
