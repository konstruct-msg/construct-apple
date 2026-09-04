//
//  PendingQueueFreshnessTests.swift
//  ConstructMessengerTests
//
//  "We are holding a handshake" and "the peer is opening a session right now" are different
//  statements, and reading the first as the second deadlocked the client.
//
//  Devices 2026-09-04 18:08. An unopenable handshake sat in the pending queue with no upper age.
//  `peerInitInFlight` therefore answered `true` forever, the core correctly and permanently
//  answered `YieldToPeer`, and every recovery path was turned away from a peer that had four
//  queued messages and no session — thirty-eight refusals in three minutes:
//
//      sendQueuedMessages: no session for ea134859… — purged 4 orphaned payload(s)
//      zombie_recover: no session for purely-outbound peer ea134859… with queued messages
//      zombie_recover_fail: Session init deferred by the core: yieldToPeer
//      tie_break_watchdog: no ack — re-sending SESSION_RESET_INIT
//      watchdog_reinit_fail: Session init deferred by the core: yieldToPeer
//
//  The core's plan was right. The evidence it was given was not.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class PendingQueueFreshnessTests: XCTestCase {

    private let peer = "14f28d31-0000-0000-0000-0000000000aa"
    private let me = "14f28d31-0000-0000-0000-0000000000bb"
    private var queue: PendingSessionQueue!

    override func setUp() {
        super.setUp()
        queue = PendingSessionQueue()
    }

    override func tearDown() {
        queue = nil
        super.tearDown()
    }

    private func incoming(msgNum: UInt32 = 0) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            from: peer,
            to: me,
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            messageNumber: msgNum,
            content: Data(repeating: 2, count: 48),
            suiteId: 1,
            timestamp: UInt64(Date().timeIntervalSince1970)
        )
    }

    /// A message that just arrived is inside any ordinary window.
    func testAFreshArrivalIsInsideTheWindow() {
        queue.enqueue(incoming(), for: peer)
        XCTAssertEqual(queue.messages(for: peer, arrivedWithin: 3600).count, 1)
    }

    /// **The deadlock, stated.** The same entry is *outside* a window that has already closed.
    /// Before this method existed the queue could only answer "is it here", which is why an entry
    /// that could never be opened kept answering yes.
    func testAnArrivalOutsideTheWindowIsNotReported() {
        queue.enqueue(incoming(), for: peer)
        XCTAssertTrue(
            queue.messages(for: peer, arrivedWithin: -1).isEmpty,
            "a window that closed before the arrival must report nothing"
        )
        XCTAssertEqual(
            queue.messages(for: peer).count, 1,
            "and the entry is still held — the window changes what is *reported*, not what is kept"
        )
    }

    /// The unwindowed reader keeps its old meaning, because the drain and the carrier search both
    /// depend on it: a handshake that has waited is still the one to open the session with.
    func testTheUnwindowedReaderStillSeesEverything() {
        queue.enqueue(incoming(msgNum: 0), for: peer)
        queue.enqueue(incoming(msgNum: 1), for: peer)
        XCTAssertEqual(queue.messages(for: peer).count, 2)
        XCTAssertEqual(queue.count(for: peer), 2)
    }

    /// Newest first, so a caller taking `.first` gets the most recent arrival rather than whichever
    /// one happens to be at the head of the FIFO.
    func testWindowedResultsAreNewestFirst() {
        let older = incoming(msgNum: 0)
        queue.enqueue(older, for: peer)
        queue.enqueue(incoming(msgNum: 1), for: peer)
        let windowed = queue.messages(for: peer, arrivedWithin: 3600)
        XCTAssertEqual(windowed.count, 2)
        XCTAssertNotEqual(windowed.first?.id, older.id, "newest first")
    }

    /// Draining and containment are unchanged by the arrival stamp — the entries are still
    /// messages to the rest of the app.
    func testDrainAndContainsSurviveTheStamp() {
        let message = incoming()
        queue.enqueue(message, for: peer)
        XCTAssertTrue(queue.contains(messageId: message.id, for: peer))
        let drained = queue.drain(for: peer)
        XCTAssertEqual(drained.map(\.id), [message.id])
        XCTAssertEqual(queue.count(for: peer), 0)
    }
}
