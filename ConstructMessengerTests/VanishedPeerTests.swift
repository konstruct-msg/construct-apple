//
//  VanishedPeerTests.swift
//  Construct MessengerTests
//
//  The three-week cursor stall, as a decision.
//
//  Device A, 2026-08-20: subscribing from `1785495484579-0` (31 July) on every reconnect, 3612 of
//  3612 replayed envelopes from one account the server answers `notFound` for, pending queue at
//  70, zero sessions established. The queue could not drain because init could not complete, and
//  a saturated queue returns `.deferred` for messages it never enqueued — a hold with no holder,
//  sitting at the head of the cursor FIFO.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class VanishedPeerTests: XCTestCase {

    private typealias Reducer = SessionReducer

    // MARK: - The decision

    /// The stall-breaker. More replayed backlog from an account that does not exist must be
    /// resolved, not queued: no session can ever be built for it, so holding the watermark buys
    /// nothing and costs every message behind it.
    func testReplayedBacklogFromAVanishedPeerIsDiscarded() {
        XCTAssertEqual(
            Reducer.vanishedPeerAction(isVanished: true, kind: .midSessionLeftover),
            .discard
        )
        XCTAssertEqual(
            Reducer.vanishedPeerAction(isVanished: true, kind: .midRatchet),
            .discard
        )
    }

    /// An account can be re-registered, so the mark has to be revocable — and a real handshake is
    /// the only evidence that could tell "they came back" from "more of the same backlog".
    /// Without this the mark is permanent and a returning contact can never reach us again.
    func testAHandshakeFromAVanishedPeerRevivesThem() {
        XCTAssertEqual(
            Reducer.vanishedPeerAction(isVanished: true, kind: .handshake),
            .revive
        )
    }

    /// An unmarked peer is untouched by any of this, whatever their envelope looks like.
    func testAnOrdinaryPeerIsUnaffected() {
        for kind in [Reducer.ReceivingInitKind.handshake, .midSessionLeftover, .midRatchet] {
            XCTAssertEqual(
                Reducer.vanishedPeerAction(isVanished: false, kind: kind),
                .proceed,
                "kind=\(kind)"
            )
        }
    }

    // MARK: - The store

    func testMarkingAndClearing() {
        let defaults = UserDefaults(suiteName: "vanished-\(UUID().uuidString)")!
        let store = VanishedPeerStore(defaults: defaults)
        let peer = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

        XCTAssertFalse(store.isVanished(peer))
        store.markVanished(peer)
        XCTAssertTrue(store.isVanished(peer))
        store.clear(peer)
        XCTAssertFalse(store.isVanished(peer), "a re-registered account must be reachable again")
    }

    /// It has to survive a relaunch: the replay that caused the stall arrives on the first
    /// subscribe after launch, before anything has had a chance to re-learn the peer is gone.
    func testTheMarkSurvivesANewStoreOverTheSameDefaults() {
        let defaults = UserDefaults(suiteName: "vanished-\(UUID().uuidString)")!
        let peer = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

        VanishedPeerStore(defaults: defaults).markVanished(peer)

        XCTAssertTrue(VanishedPeerStore(defaults: defaults).isVanished(peer))
    }

    func testAnEmptyIdIsNeverMarked() {
        let defaults = UserDefaults(suiteName: "vanished-\(UUID().uuidString)")!
        let store = VanishedPeerStore(defaults: defaults)
        store.markVanished("")
        XCTAssertFalse(store.isVanished(""))
    }

    /// Two peers are independent — marking one must not silence the other.
    func testPeersAreIndependent() {
        let defaults = UserDefaults(suiteName: "vanished-\(UUID().uuidString)")!
        let store = VanishedPeerStore(defaults: defaults)
        store.markVanished("gone")
        XCTAssertTrue(store.isVanished("gone"))
        XCTAssertFalse(store.isVanished("present"))
    }
}
