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

    // MARK: 3. END_SESSION during init — state reset

    @MainActor
    func testEndSessionDuringInit_StateReset() {
        let d = SessionDriver()
        let sender = "charlie-\(UUID().uuidString)"

        d.send(.initStarted, for: sender)
        XCTAssertTrue(d.isInitializing(sender))

        d.send(.endSessionReceived, for: sender)

        XCTAssertTrue(d.isIdle(sender), "State must reset to idle")
    }

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

    // MARK: 7. Re-init after END_SESSION — new message triggers fresh init

    @MainActor
    func testReInitAfterEndSession_NewMessageStartsFreshInit() {
        let d = SessionDriver()
        let sender = "frank-\(UUID().uuidString)"

        d.send(.initStarted, for: sender)
        d.send(.initSucceeded(at: ts), for: sender)
        XCTAssertTrue(d.isActive(sender))

        d.send(.endSessionReceived, for: sender)
        XCTAssertTrue(d.isIdle(sender))

        d.send(.initStarted, for: sender)
        XCTAssertTrue(d.isInitializing(sender), "Second init cycle must start after END_SESSION reset")
    }

    // MARK: 8. Rapid END_SESSION storm — state stabilises after every wipe

    @MainActor
    func testEndSessionStorm_StateAlwaysIdle() {
        let d = SessionDriver()
        let sender = "gary-\(UUID().uuidString)"

        d.send(.initStarted, for: sender)
        d.send(.initSucceeded(at: ts), for: sender)

        for _ in 1...5 {
            d.send(.endSessionReceived, for: sender)
            XCTAssertTrue(d.isIdle(sender))
        }
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

    // MARK: 11. Inbound control coalescing — the window that is still the client's

    /// The outbound END_SESSION window left this layer on 2026-09-22 (it is
    /// `orchestration::session_machine`'s, asked through `CfeIncomingEvent.teardownRequested`).
    /// The receive-side coalesce is not the same question and stays: it is about how often we
    /// *act on* a control message, which is a property of the inbound path.
    @MainActor
    func testShouldHandleInboundControl_RateLimit() {
        let now = Date()
        let cooldown: TimeInterval = 30

        // Receive-side control coalesce uses the same window semantics.
        XCTAssertTrue(SessionReducer.shouldHandleInboundControl(
            lastHandledAt: nil, now: now, cooldown: cooldown))
        XCTAssertFalse(SessionReducer.shouldHandleInboundControl(
            lastHandledAt: now.addingTimeInterval(-1), now: now, cooldown: cooldown))
        XCTAssertTrue(SessionReducer.shouldHandleInboundControl(
            lastHandledAt: now.addingTimeInterval(-30), now: now, cooldown: cooldown))
    }

    // MARK: 12. END_SESSION staleness — the post-launch reset hypothesis

    /// Pins the stale-END_SESSION decision the device logs are instrumented around.
    /// The `establishedAt == nil` case (no in-memory establishment, e.g. right after launch)
    /// currently returns false — i.e. CANNOT filter — which is the suspected cause of healthy
    /// sessions being reset by a re-delivered old END_SESSION. Phase 3 (persisted establishment)
    /// will change this; this test documents the present behaviour.
    @MainActor
    func testIsEndSessionStale_Decision() {
        let fudge: UInt64 = 5

        // No in-memory establishment → cannot filter (the post-launch blind spot).
        XCTAssertFalse(SessionReducer.isEndSessionStale(establishedAt: nil, timestamp: 100, fudgeSeconds: fudge))

        // END_SESSION clearly pre-dates establishment (beyond fudge) → stale, filtered.
        XCTAssertTrue(SessionReducer.isEndSessionStale(establishedAt: 1_000, timestamp: 900, fudgeSeconds: fudge))

        // END_SESSION at/after establishment → fresh, acted on.
        XCTAssertFalse(SessionReducer.isEndSessionStale(establishedAt: 1_000, timestamp: 1_000, fudgeSeconds: fudge))
        XCTAssertFalse(SessionReducer.isEndSessionStale(establishedAt: 1_000, timestamp: 1_100, fudgeSeconds: fudge))

        // Within the fudge window before establishment → treated as fresh (clock-skew tolerance).
        XCTAssertFalse(SessionReducer.isEndSessionStale(establishedAt: 1_000, timestamp: 996, fudgeSeconds: fudge))
        // Just outside the fudge window → stale.
        XCTAssertTrue(SessionReducer.isEndSessionStale(establishedAt: 1_000, timestamp: 994, fudgeSeconds: fudge))
    }
}
