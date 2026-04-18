//
//  SessionRaceConditionTests.swift
//  ConstructMessengerTests
//
//  Tests for the Swift session state machine — the concurrency guards that prevent
//  double-init, message loss during init, and orphaned state after END_SESSION.
//
//  These tests use a lightweight `MockSessionStateMachine` that reimplements the
//  same locking pattern as SessionCoordinator (ContactSessionState + pendingFirstMessages)
//  so we can drive edge cases without needing CoreData, Rust, or a live gRPC stream.
//

import XCTest
@testable import Construct_Messenger

// MARK: - Mock session state machine

/// Minimal reimplementation of SessionCoordinator's concurrency guards.
/// Mirrors: contactSessionState, pendingFirstMessages, beginInit, markActive.
@MainActor
private final class MockSessionStateMachine {

    enum State: Equatable {
        case idle
        case initializing
        case active
    }

    // Per-contact state
    private var states: [String: State] = [:]

    // Pending message queue (mirrors pendingFirstMessages)
    private var pendingQueue: [String: [String]] = [:]

    // Tracks how many times initSession was actually invoked per contact
    private(set) var initInvokedCount: [String: Int] = [:]

    // Tracks how many times a message was processed
    private(set) var processedMessages: [String] = []

    // MARK: - State accessors

    func state(for userId: String) -> State {
        states[userId] ?? .idle
    }

    func isInitializing(_ userId: String) -> Bool {
        states[userId] == .initializing
    }

    // MARK: - Simulate incoming message

    /// Route an incoming message from `senderId`.
    /// - If already initializing: enqueue the message.
    /// - If active session exists: process immediately.
    /// - Otherwise: start init, enqueue message, mark as initializing.
    func handleIncomingMessage(_ messageId: String, from senderId: String) {
        switch states[senderId] ?? .idle {
        case .initializing:
            // Init already in flight — queue the message
            pendingQueue[senderId, default: []].append(messageId)

        case .active:
            processedMessages.append(messageId)

        case .idle:
            // Kick off init and queue the message
            states[senderId] = .initializing
            initInvokedCount[senderId, default: 0] += 1
            pendingQueue[senderId, default: []].append(messageId)
        }
    }

    /// Called when session init completes successfully.
    func onInitSuccess(for userId: String) {
        states[userId] = .active
        // Drain the pending queue
        let queued = pendingQueue.removeValue(forKey: userId) ?? []
        processedMessages.append(contentsOf: queued)
    }

    /// Called when session init fails (or END_SESSION received during init).
    func onInitFailure(for userId: String) {
        states[userId] = .idle
        pendingQueue.removeValue(forKey: userId)
    }

    /// Called when END_SESSION received from peer — wipe state.
    func onEndSession(from userId: String) {
        states[userId] = .idle
        pendingQueue.removeValue(forKey: userId)
    }

    func pendingCount(for userId: String) -> Int {
        pendingQueue[userId]?.count ?? 0
    }

    func resetProcessed() {
        processedMessages.removeAll()
    }
}

// MARK: - Tests

final class SessionRaceConditionTests: XCTestCase {

    // MARK: 1. Double-init guard: second call while init in-flight is rejected

    /// When two messages from the same sender arrive before session init completes,
    /// only ONE init attempt must be made. The second message is queued, not dropped.
    @MainActor
    func testDoubleInitGuard_SecondMessageQueued_InitCalledOnce() async {
        let machine = MockSessionStateMachine()
        let sender = "alice-\(UUID().uuidString)"

        // First message: triggers init
        machine.handleIncomingMessage("msg-1", from: sender)
        XCTAssertEqual(machine.state(for: sender), .initializing)
        XCTAssertEqual(machine.initInvokedCount[sender], 1, "Init must be started exactly once")
        XCTAssertEqual(machine.pendingCount(for: sender), 1, "First message must be queued")

        // Second message arrives while init is in-flight
        machine.handleIncomingMessage("msg-2", from: sender)
        XCTAssertEqual(machine.initInvokedCount[sender], 1, "Init must NOT be started a second time")
        XCTAssertEqual(machine.pendingCount(for: sender), 2, "Second message must also be queued")
        XCTAssertEqual(machine.state(for: sender), .initializing, "State must remain .initializing")
    }

    // MARK: 2. Pending queue is drained after init success — messages not lost

    /// Messages queued during init must all be processed after init succeeds.
    /// This is the core invariant preventing the "first message lost" bug.
    @MainActor
    func testMessageQueuedDuringInit_DrainedAfterSuccess_NoMessageLost() async {
        let machine = MockSessionStateMachine()
        let sender = "bob-\(UUID().uuidString)"

        // 5 messages arrive while init is in-flight
        for i in 1...5 {
            machine.handleIncomingMessage("msg-\(i)", from: sender)
        }
        XCTAssertEqual(machine.pendingCount(for: sender), 5)
        XCTAssertTrue(machine.processedMessages.isEmpty, "No messages processed yet — init not done")

        // Init completes
        machine.onInitSuccess(for: sender)

        XCTAssertEqual(machine.state(for: sender), .active)
        XCTAssertEqual(machine.pendingCount(for: sender), 0, "Queue must be empty after drain")
        XCTAssertEqual(machine.processedMessages.count, 5, "All 5 messages must be processed")

        for i in 1...5 {
            XCTAssertTrue(machine.processedMessages.contains("msg-\(i)"),
                          "msg-\(i) must be in processed set")
        }
    }

    // MARK: 3. END_SESSION during init — queue cleared, no orphan

    /// If END_SESSION arrives while session init is in-flight, the queue must be cleared
    /// and state reset to idle. No orphaned pending messages.
    @MainActor
    func testEndSessionDuringInit_QueueClearedAndStateReset() async {
        let machine = MockSessionStateMachine()
        let sender = "charlie-\(UUID().uuidString)"

        machine.handleIncomingMessage("msg-A", from: sender)
        machine.handleIncomingMessage("msg-B", from: sender)
        XCTAssertEqual(machine.pendingCount(for: sender), 2)

        // END_SESSION arrives before init completes
        machine.onEndSession(from: sender)

        XCTAssertEqual(machine.state(for: sender), .idle, "State must reset to idle")
        XCTAssertEqual(machine.pendingCount(for: sender), 0, "Queue must be empty — no orphan")
        XCTAssertTrue(machine.processedMessages.isEmpty, "No messages must be processed")
    }

    // MARK: 4. Init failure — state resets, queue cleared

    @MainActor
    func testInitFailure_StateResetsToIdle_QueueCleared() async {
        let machine = MockSessionStateMachine()
        let sender = "dave-\(UUID().uuidString)"

        machine.handleIncomingMessage("msg-X", from: sender)
        XCTAssertEqual(machine.state(for: sender), .initializing)

        machine.onInitFailure(for: sender)

        XCTAssertEqual(machine.state(for: sender), .idle)
        XCTAssertEqual(machine.pendingCount(for: sender), 0)
    }

    // MARK: 5. Active session — message processed immediately, no queuing

    @MainActor
    func testActiveSession_MessageProcessedImmediately() async {
        let machine = MockSessionStateMachine()
        let sender = "eve-\(UUID().uuidString)"

        // Establish session
        machine.handleIncomingMessage("ping", from: sender)
        machine.onInitSuccess(for: sender)
        machine.resetProcessed()  // reset counter after drain

        // Next message with active session
        machine.handleIncomingMessage("user-msg", from: sender)

        XCTAssertEqual(machine.state(for: sender), .active)
        XCTAssertEqual(machine.processedMessages, ["user-msg"],
                       "Message must be processed immediately when session is active")
        XCTAssertEqual(machine.pendingCount(for: sender), 0, "No queuing for active session")
    }

    // MARK: 6. Multi-contact isolation — init for one contact doesn't affect others

    @MainActor
    func testMultiContactIsolation_InitForOneContactDoesNotAffectOthers() async {
        let machine = MockSessionStateMachine()
        let alice = "alice-\(UUID().uuidString)"
        let bob   = "bob-\(UUID().uuidString)"

        // Alice's init in-flight
        machine.handleIncomingMessage("alice-msg-1", from: alice)
        XCTAssertEqual(machine.state(for: alice), .initializing)

        // Bob's message arrives independently — should start its own init
        machine.handleIncomingMessage("bob-msg-1", from: bob)
        XCTAssertEqual(machine.state(for: bob), .initializing)
        XCTAssertEqual(machine.initInvokedCount[alice], 1)
        XCTAssertEqual(machine.initInvokedCount[bob], 1)

        // Alice's init succeeds
        machine.onInitSuccess(for: alice)
        XCTAssertEqual(machine.state(for: alice), .active)
        XCTAssertEqual(machine.state(for: bob), .initializing,
                       "Bob's init must be unaffected by Alice's success")

        // Bob's init fails
        machine.onInitFailure(for: bob)
        XCTAssertEqual(machine.state(for: bob), .idle)
        XCTAssertEqual(machine.state(for: alice), .active,
                       "Alice's state must be unaffected by Bob's failure")
    }

    // MARK: 7. Re-init after END_SESSION — new message triggers fresh init

    @MainActor
    func testReInitAfterEndSession_NewMessageStartsFreshInit() async {
        let machine = MockSessionStateMachine()
        let sender = "frank-\(UUID().uuidString)"

        // First init cycle
        machine.handleIncomingMessage("msg-1", from: sender)
        machine.onInitSuccess(for: sender)
        XCTAssertEqual(machine.state(for: sender), .active)

        // END_SESSION received
        machine.onEndSession(from: sender)
        XCTAssertEqual(machine.state(for: sender), .idle)

        // New message arrives — must trigger a fresh init
        machine.handleIncomingMessage("msg-2", from: sender)
        XCTAssertEqual(machine.state(for: sender), .initializing)
        XCTAssertEqual(machine.initInvokedCount[sender], 2,
                       "Second init cycle must be started after END_SESSION reset")
    }

    // MARK: 8. Rapid END_SESSION storm — state stabilises after last wipe

    /// Simulates the production bug: multiple END_SESSION signals from the same peer
    /// arriving in rapid succession. Each wipe should leave state as .idle.
    @MainActor
    func testEndSessionStorm_StateAlwaysIdle_NoOrphan() async {
        let machine = MockSessionStateMachine()
        let sender = "gary-\(UUID().uuidString)"

        machine.handleIncomingMessage("msg-1", from: sender)
        machine.onInitSuccess(for: sender)

        // 5 END_SESSION signals (e.g. from stream dedup misfire)
        for _ in 1...5 {
            machine.onEndSession(from: sender)
            XCTAssertEqual(machine.state(for: sender), .idle)
            XCTAssertEqual(machine.pendingCount(for: sender), 0)
        }
    }
}
