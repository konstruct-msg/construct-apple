//
//  SessionRaceConditionTests.swift
//  ConstructMessengerTests
//
//  Tests for the Swift session state machine — the concurrency guards that prevent
//  double-init, message loss during init, and orphaned state after END_SESSION.
//
//  These drive the REAL production `SessionReducer.reduce` — the phase lifecycle used by
//  SessionCoordinator — not a parallel reimplementation.
//
//  The queue half of this file went on 2026-09-26: `incomingDisposition` and the drain / clear
//  effects decided for `PendingSessionQueue`, and messages waiting for a session now wait in the
//  core's queue. The double-init guard is the core machine's `WantToOpen` → `WaitForOpen`, the
//  drain is `after_session_opened`, both tested in `construct-core`.
//

import XCTest
@testable import Construct_Messenger

// MARK: - Driver over the real SessionReducer

@MainActor
private final class SessionDriver {
    /// Real reducer phase, keyed by peer id (`nil` == absent / idle).
    private(set) var phases: [String: SessionReducer.Phase] = [:]

    func send(_ event: SessionReducer.Event, for userId: String) {
        phases[userId] = SessionReducer.reduce(phases[userId], on: event)
    }

    func isIdle(_ userId: String) -> Bool { phases[userId] == nil }
    func isInitializing(_ userId: String) -> Bool {
        if case .initializing = phases[userId] { return true }
        return false
    }
    func isActive(_ userId: String) -> Bool {
        if case .active = phases[userId] { return true }
        return false
    }
}

// MARK: - Tests

final class SessionRaceConditionTests: XCTestCase {

    /// Fixed timestamp for `markActive`/`initSucceeded` — the reducer never reads the clock,
    /// so any stable value works and keeps tests deterministic.
    private let ts: UInt64 = 1_000

    // MARK: 4. Init failure — state resets

    @MainActor
    func testInitFailure_StateResetsToIdle() {
        let d = SessionDriver()
        let sender = "dave-\(UUID().uuidString)"

        d.send(.initStarted, for: sender)
        XCTAssertTrue(d.isInitializing(sender))

        d.send(.initFailed, for: sender)

        XCTAssertTrue(d.isIdle(sender))
    }

    // MARK: 6. Multi-contact isolation — init for one contact doesn't affect others

    @MainActor
    func testMultiContactIsolation_InitForOneContactDoesNotAffectOthers() {
        let d = SessionDriver()
        let alice = "alice-\(UUID().uuidString)"
        let bob   = "bob-\(UUID().uuidString)"

        d.send(.initStarted, for: alice)
        XCTAssertTrue(d.isInitializing(alice))

        d.send(.initStarted, for: bob)
        XCTAssertTrue(d.isInitializing(bob))

        d.send(.initSucceeded(at: ts), for: alice)
        XCTAssertTrue(d.isActive(alice))
        XCTAssertTrue(d.isInitializing(bob), "Bob's init must be unaffected by Alice's success")

        d.send(.initFailed, for: bob)
        XCTAssertTrue(d.isIdle(bob))
        XCTAssertTrue(d.isActive(alice), "Alice's state must be unaffected by Bob's failure")
    }

    // MARK: 9. initEnded never clobbers an .active set inside the same init scope

    /// Mirrors `beginInit`'s returned closure: when a success path marks the session active
    /// *during* an init scope, the trailing `initEnded` must not wipe it back to idle.
    @MainActor
    func testInitEnded_DoesNotClobberActive() {
        let d = SessionDriver()
        let sender = "heidi-\(UUID().uuidString)"

        d.send(.initStarted, for: sender)
        XCTAssertTrue(d.isInitializing(sender))

        d.send(.markActive(at: ts), for: sender)
        XCTAssertTrue(d.isActive(sender))

        d.send(.initEnded, for: sender)
        XCTAssertTrue(d.isActive(sender), "initEnded must not clobber an .active set during init")
    }
}
