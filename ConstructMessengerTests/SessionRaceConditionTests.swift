//
//  SessionRaceConditionTests.swift
//  ConstructMessengerTests
//
//  Tests for the Swift session state machine — the concurrency guards that prevent
//  double-init, message loss during init, and orphaned state after END_SESSION.
//
//  Phase 1 / 1.5 of SESSION_COORDINATOR_REFACTOR_SPEC: these tests drive the REAL
//  production `SessionReducer` — both `incomingDisposition` (the queue decision now used
//  by MessageRouter) and `reduce` (the phase lifecycle used by SessionCoordinator) — not a
//  parallel reimplementation. The only test-side code is a trivial effector (`SessionDriver`)
//  that applies the emitted effects to an in-memory queue, mirroring ConnectionLoopTests.
//

import XCTest
@testable import Construct_Messenger

// MARK: - In-test effector over the real SessionReducer

/// Applies the effects emitted by the production `SessionReducer` to simple in-memory
/// bookkeeping (the message queue + processed log + init counter that MessageRouter and
/// SessionCoordinator own in production). All decision logic lives in `SessionReducer`.
@MainActor
private final class SessionDriver {

    /// Real reducer phase, keyed by peer id (`nil` == absent / idle).
    private(set) var phases: [String: SessionReducer.Phase] = [:]

    // Effector-owned bookkeeping.
    private(set) var pending: [String: [String]] = [:]
    private(set) var processed: [String] = []
    private(set) var initInvokedCount: [String: Int] = [:]

    /// Drive a phase-lifecycle event through the real reducer and perform its effects.
    func send(_ event: SessionReducer.Event, for userId: String) {
        let (newPhase, effects) = SessionReducer.reduce(phases[userId], on: event)
        phases[userId] = newPhase
        for effect in effects { perform(effect, id: nil, for: userId) }
    }

    /// Drive an incoming message through the real `incomingDisposition`, then — if it starts
    /// init — mark the phase `.initializing`, exactly as the init executor does in production.
    func handleIncoming(_ id: String, from userId: String, hasActiveSession: Bool = false) {
        let effects = SessionReducer.incomingDisposition(
            hasActiveSession: hasActiveSession,
            isInitInFlight: isInitializing(userId)
        )
        for effect in effects { perform(effect, id: id, for: userId) }
        if effects.contains(.startInit) { send(.initStarted, for: userId) }
    }

    private func perform(_ effect: SessionReducer.Effect, id: String?, for userId: String) {
        switch effect {
        case .startInit:
            initInvokedCount[userId, default: 0] += 1
        case .queueMessage:
            if let id { pending[userId, default: []].append(id) }
        case .processMessage:
            if let id { processed.append(id) }
        case .drainQueuedMessages:
            let queued = pending.removeValue(forKey: userId) ?? []
            processed.append(contentsOf: queued)
        case .clearQueuedMessages:
            pending.removeValue(forKey: userId)
        }
    }

    // MARK: Convenience accessors

    func isIdle(_ userId: String) -> Bool { phases[userId] == nil }

    func isInitializing(_ userId: String) -> Bool {
        if case .initializing = phases[userId] { return true }
        return false
    }

    func isActive(_ userId: String) -> Bool {
        if case .active = phases[userId] { return true }
        return false
    }

    func pendingCount(for userId: String) -> Int { pending[userId]?.count ?? 0 }

    func resetProcessed() { processed.removeAll() }
}

// MARK: - Tests

final class SessionRaceConditionTests: XCTestCase {

    /// Fixed timestamp for `markActive`/`initSucceeded` — the reducer never reads the clock,
    /// so any stable value works and keeps tests deterministic.
    private let ts: UInt64 = 1_000

    // MARK: 1. Double-init guard: second message while init in-flight is queued, not re-inited

    @MainActor
    func testDoubleInitGuard_SecondMessageQueued_InitCalledOnce() {
        let d = SessionDriver()
        let sender = "alice-\(UUID().uuidString)"

        d.handleIncoming("msg-1", from: sender)
        XCTAssertTrue(d.isInitializing(sender))
        XCTAssertEqual(d.initInvokedCount[sender], 1, "Init must be started exactly once")
        XCTAssertEqual(d.pendingCount(for: sender), 1, "First message must be queued")

        d.handleIncoming("msg-2", from: sender)
        XCTAssertEqual(d.initInvokedCount[sender], 1, "Init must NOT be started a second time")
        XCTAssertEqual(d.pendingCount(for: sender), 2, "Second message must also be queued")
        XCTAssertTrue(d.isInitializing(sender), "State must remain .initializing")
    }

    // MARK: 2. Pending queue is drained after init success — messages not lost

    @MainActor
    func testMessageQueuedDuringInit_DrainedAfterSuccess_NoMessageLost() {
        let d = SessionDriver()
        let sender = "bob-\(UUID().uuidString)"

        for i in 1...5 { d.handleIncoming("msg-\(i)", from: sender) }
        XCTAssertEqual(d.pendingCount(for: sender), 5)
        XCTAssertTrue(d.processed.isEmpty, "No messages processed yet — init not done")

        d.send(.initSucceeded(at: ts), for: sender)

        XCTAssertTrue(d.isActive(sender))
        XCTAssertEqual(d.pendingCount(for: sender), 0, "Queue must be empty after drain")
        XCTAssertEqual(d.processed.count, 5, "All 5 messages must be processed")
        for i in 1...5 {
            XCTAssertTrue(d.processed.contains("msg-\(i)"), "msg-\(i) must be in processed set")
        }
    }

    // MARK: 3. END_SESSION during init — queue cleared, no orphan

    @MainActor
    func testEndSessionDuringInit_QueueClearedAndStateReset() {
        let d = SessionDriver()
        let sender = "charlie-\(UUID().uuidString)"

        d.handleIncoming("msg-A", from: sender)
        d.handleIncoming("msg-B", from: sender)
        XCTAssertEqual(d.pendingCount(for: sender), 2)

        d.send(.endSessionReceived, for: sender)

        XCTAssertTrue(d.isIdle(sender), "State must reset to idle")
        XCTAssertEqual(d.pendingCount(for: sender), 0, "Queue must be empty — no orphan")
        XCTAssertTrue(d.processed.isEmpty, "No messages must be processed")
    }

    // MARK: 4. Init failure — state resets, queue cleared

    @MainActor
    func testInitFailure_StateResetsToIdle_QueueCleared() {
        let d = SessionDriver()
        let sender = "dave-\(UUID().uuidString)"

        d.handleIncoming("msg-X", from: sender)
        XCTAssertTrue(d.isInitializing(sender))

        d.send(.initFailed, for: sender)

        XCTAssertTrue(d.isIdle(sender))
        XCTAssertEqual(d.pendingCount(for: sender), 0)
    }

    // MARK: 5. Active session — message processed immediately, no queuing

    @MainActor
    func testActiveSession_MessageProcessedImmediately() {
        let d = SessionDriver()
        let sender = "eve-\(UUID().uuidString)"

        d.handleIncoming("ping", from: sender)
        d.send(.initSucceeded(at: ts), for: sender)
        d.resetProcessed()

        d.handleIncoming("user-msg", from: sender, hasActiveSession: true)

        XCTAssertTrue(d.isActive(sender))
        XCTAssertEqual(d.processed, ["user-msg"],
                       "Message must be processed immediately when session is active")
        XCTAssertEqual(d.pendingCount(for: sender), 0, "No queuing for active session")
    }

    // MARK: 6. Multi-contact isolation — init for one contact doesn't affect others

    @MainActor
    func testMultiContactIsolation_InitForOneContactDoesNotAffectOthers() {
        let d = SessionDriver()
        let alice = "alice-\(UUID().uuidString)"
        let bob   = "bob-\(UUID().uuidString)"

        d.handleIncoming("alice-msg-1", from: alice)
        XCTAssertTrue(d.isInitializing(alice))

        d.handleIncoming("bob-msg-1", from: bob)
        XCTAssertTrue(d.isInitializing(bob))
        XCTAssertEqual(d.initInvokedCount[alice], 1)
        XCTAssertEqual(d.initInvokedCount[bob], 1)

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

        d.handleIncoming("msg-1", from: sender)
        d.send(.initSucceeded(at: ts), for: sender)
        XCTAssertTrue(d.isActive(sender))

        d.send(.endSessionReceived, for: sender)
        XCTAssertTrue(d.isIdle(sender))

        d.handleIncoming("msg-2", from: sender)
        XCTAssertTrue(d.isInitializing(sender))
        XCTAssertEqual(d.initInvokedCount[sender], 2,
                       "Second init cycle must be started after END_SESSION reset")
    }

    // MARK: 8. Rapid END_SESSION storm — state stabilises after every wipe

    @MainActor
    func testEndSessionStorm_StateAlwaysIdle_NoOrphan() {
        let d = SessionDriver()
        let sender = "gary-\(UUID().uuidString)"

        d.handleIncoming("msg-1", from: sender)
        d.send(.initSucceeded(at: ts), for: sender)

        for _ in 1...5 {
            d.send(.endSessionReceived, for: sender)
            XCTAssertTrue(d.isIdle(sender))
            XCTAssertEqual(d.pendingCount(for: sender), 0)
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

    // MARK: 10. incomingDisposition — the pure decision MessageRouter now uses

    /// Pins the disposition contract directly (independent of the queue effector).
    @MainActor
    func testIncomingDisposition_DecisionTable() {
        // Active session → process immediately.
        XCTAssertEqual(
            SessionReducer.incomingDisposition(hasActiveSession: true, isInitInFlight: false),
            [.processMessage])
        // Active wins even if a (stale) init marker is set.
        XCTAssertEqual(
            SessionReducer.incomingDisposition(hasActiveSession: true, isInitInFlight: true),
            [.processMessage])
        // No session, none in flight → first message: start init + queue.
        XCTAssertEqual(
            SessionReducer.incomingDisposition(hasActiveSession: false, isInitInFlight: false),
            [.startInit, .queueMessage])
        // No session, init already underway → queue only, no second init.
        XCTAssertEqual(
            SessionReducer.incomingDisposition(hasActiveSession: false, isInitInFlight: true),
            [.queueMessage])
    }

    // MARK: 11. END_SESSION cooldown — the single rate-limit decision

    /// Pins the storm-prevention rate limit used by the unified END_SESSION choke point.
    @MainActor
    func testShouldSendEndSession_RateLimit() {
        let now = Date()
        let cooldown: TimeInterval = 30

        // Never sent before → allowed.
        XCTAssertTrue(SessionReducer.shouldSendEndSession(lastSentAt: nil, now: now, cooldown: cooldown))

        // Sent just now → suppressed.
        XCTAssertFalse(SessionReducer.shouldSendEndSession(
            lastSentAt: now.addingTimeInterval(-1), now: now, cooldown: cooldown))

        // Within the window → suppressed.
        XCTAssertFalse(SessionReducer.shouldSendEndSession(
            lastSentAt: now.addingTimeInterval(-29), now: now, cooldown: cooldown))

        // Exactly at the boundary → allowed (>= cooldown).
        XCTAssertTrue(SessionReducer.shouldSendEndSession(
            lastSentAt: now.addingTimeInterval(-30), now: now, cooldown: cooldown))

        // Well past the window → allowed.
        XCTAssertTrue(SessionReducer.shouldSendEndSession(
            lastSentAt: now.addingTimeInterval(-120), now: now, cooldown: cooldown))
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
