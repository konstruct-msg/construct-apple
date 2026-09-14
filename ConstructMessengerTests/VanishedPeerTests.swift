//
//  VanishedPeerTests.swift
//  Construct MessengerTests
//
//  The three-week cursor stall, and the oscillation the first fix introduced.
//
//  Device A, 2026-08-20: subscribing from `1785495484579-0` (31 July) on every reconnect, 3612 of
//  3612 replayed envelopes from one account the server answers `notFound` for, pending queue at
//  70, zero sessions established. A saturated queue returns `.deferred` for messages it never
//  enqueued — a hold with no holder — and one of those sat at the head of the cursor FIFO.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class VanishedPeerTests: XCTestCase {

    private typealias Reducer = SessionReducer
    private let t0 = Date(timeIntervalSince1970: 1_787_248_000)
    private let peer = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

    private func store() -> VanishedPeerStore {
        VanishedPeerStore(defaults: UserDefaults(suiteName: "vanished-\(UUID().uuidString)")!)
    }

    // MARK: - The decision

    /// The stall-breaker: replayed backlog from an account that does not exist is resolved, not
    /// queued. No session can ever be built for it, so holding the watermark costs every message
    /// behind it and buys nothing.
    func testFreshlyMarkedPeerHasTheirBacklogDiscarded() {
        XCTAssertEqual(Reducer.vanishedPeerAction(markedAt: t0, now: t0.addingTimeInterval(1)), .discard)
    }

    // The regression that made the first fix useless has no test here, deliberately.
    //
    // `.revive` on a handshake looked right and was not: `receivingInitKind` cannot tell a classic
    // 3-DH handshake from a classic leftover, and a dead account's backlog is all leftovers — so
    // every replayed envelope cleared the mark (marked 17:45:33, cleared 17:45:53, marked
    // 17:45:55, cleared 17:45:58) and the cursor never moved.
    //
    // What prevents it now is that the decision takes no envelope: there is no parameter for a
    // leftover to masquerade in. A test asserting that would be asserting the signature, which the
    // compiler already does, and this repo has paid for tests that could not fail.

    /// The mark has to expire: an account can be re-registered, and nothing else would ask again.
    func testTheMarkExpiresSoTheServerIsAskedAgain() {
        let after = t0.addingTimeInterval(Reducer.vanishedPeerRetryAfter + 1)
        XCTAssertEqual(Reducer.vanishedPeerAction(markedAt: t0, now: after), .proceed)
    }

    /// Exactly at the window is already lapsed (`<`, not `<=`). Pinned because the two readings
    /// differ by one bundle fetch an hour, and nothing else states which one this is.
    func testTheBoundaryCountsAsLapsed() {
        XCTAssertEqual(
            Reducer.vanishedPeerAction(markedAt: t0, now: t0.addingTimeInterval(Reducer.vanishedPeerRetryAfter)),
            .proceed
        )
        XCTAssertEqual(
            Reducer.vanishedPeerAction(markedAt: t0, now: t0.addingTimeInterval(Reducer.vanishedPeerRetryAfter - 1)),
            .discard
        )
    }

    func testAnUnmarkedPeerProceeds() {
        XCTAssertEqual(Reducer.vanishedPeerAction(markedAt: nil, now: t0), .proceed)
    }

    // MARK: - The store

    func testMarkingRecordsTheTimeAndClearingRemovesIt() {
        let s = store()
        XCTAssertNil(s.markedAt(peer))
        s.markVanished(peer, now: t0)
        XCTAssertEqual(s.markedAt(peer), t0)
        s.clear(peer)
        XCTAssertNil(s.markedAt(peer), "a re-registered account must be reachable again")
    }

    /// A re-test that comes back `notFound` again restarts the window. Without this the mark
    /// would go stale permanently and every hour would let another burst of backlog through.
    func testRemarkingRestartsTheWindow() {
        let s = store()
        s.markVanished(peer, now: t0)
        let later = t0.addingTimeInterval(Reducer.vanishedPeerRetryAfter + 10)
        s.markVanished(peer, now: later)

        XCTAssertEqual(s.markedAt(peer), later)
        XCTAssertEqual(Reducer.vanishedPeerAction(markedAt: s.markedAt(peer), now: later.addingTimeInterval(60)), .discard)
    }

    /// It has to survive a relaunch: the replay that caused the stall arrives on the first
    /// subscribe after launch, before anything could re-learn the peer is gone.
    func testTheMarkSurvivesANewStoreOverTheSameDefaults() {
        let defaults = UserDefaults(suiteName: "vanished-\(UUID().uuidString)")!
        VanishedPeerStore(defaults: defaults).markVanished(peer, now: t0)
        XCTAssertEqual(VanishedPeerStore(defaults: defaults).markedAt(peer), t0)
    }

    func testAnEmptyIdIsNeverMarked() {
        let s = store()
        s.markVanished("", now: t0)
        XCTAssertNil(s.markedAt(""))
    }

    func testPeersAreIndependent() {
        let s = store()
        s.markVanished("gone", now: t0)
        XCTAssertNotNil(s.markedAt("gone"))
        XCTAssertNil(s.markedAt("present"))
    }
}
