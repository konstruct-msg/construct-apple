//
//  ProactiveInitCoalescingTests.swift
//  ConstructMessengerTests
//
//  Single-flight invariant for SessionInitializationService.initializeSessionProactively.
//
//  Two concurrent runs each fetch a bundle with consumeOneTimePrekey: true and each call
//  initializeSession(deleteExisting: true), so the second silently replaces the first's
//  session. The X3DH carrier already sent for run #1 (SESSION_RESET_INIT) then references a
//  ratchet we no longer hold while our own messages continue on run #2 — the peer establishes
//  from one and receives on the other, and diverges on the very next message.
//
//  Observed on device 2026-07-31: `initiator_announce` (END_SESSION received) and
//  `queue_message` (user typed) started runs 1s apart and forced one guaranteed heal cycle.
//  See client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ProactiveInitCoalescingTests: XCTestCase {

    private var service: SessionInitializationService { SessionInitializationService.shared }

    override func tearDown() async throws {
        service.proactiveInitOverrideForTests = nil
        try await super.tearDown()
    }

    /// Concurrent callers for the SAME peer must produce exactly one init run,
    /// and every caller must still receive the outcome (coalesced, not skipped —
    /// skipping would strand the late joiner's queued messages, since onSuccess flushes them).
    func testConcurrentCallers_SamePeer_RunInitOnce_AndAllGetOutcome() async {
        let runs = Counter()
        let gate = AsyncGate()
        service.proactiveInitOverrideForTests = { _ in
            await runs.increment()
            await gate.wait()   // hold the run open so all callers pile up on it
            return true
        }

        let successes = Counter()
        async let a: Void = call(peer: "peer-1", onSuccess: { await successes.increment() })
        async let b: Void = call(peer: "peer-1", onSuccess: { await successes.increment() })
        async let c: Void = call(peer: "peer-1", onSuccess: { await successes.increment() })

        // Let all three reach the coalescer before the single run completes.
        try? await Task.sleep(nanoseconds: 120_000_000)
        await gate.open()
        _ = await (a, b, c)

        let runCount = await runs.value
        XCTAssertEqual(runCount, 1,
                       "3 concurrent callers must coalesce onto ONE init run (got \(runCount)) — " +
                       "two runs burn two peer OTPKs and leave the SRI on a replaced ratchet")
        let successCount = await successes.value
        XCTAssertEqual(successCount, 3,
                       "every coalesced caller must receive the outcome (got \(successCount)) — " +
                       "a skipped caller strands its queued messages")
    }

    /// Different peers are independent — coalescing must key on the peer, not be a global lock.
    func testConcurrentCallers_DifferentPeers_RunIndependently() async {
        let runs = Counter()
        service.proactiveInitOverrideForTests = { _ in
            await runs.increment()
            return true
        }

        async let a: Void = call(peer: "peer-1", onSuccess: {})
        async let b: Void = call(peer: "peer-2", onSuccess: {})
        _ = await (a, b)

        let runCount = await runs.value
        XCTAssertEqual(runCount, 2, "distinct peers must not share a single-flight slot")
    }

    /// The slot must be released after a run so a later, genuinely-new init is not swallowed.
    func testSequentialCalls_SamePeer_RunEachTime() async {
        let runs = Counter()
        service.proactiveInitOverrideForTests = { _ in
            await runs.increment()
            return true
        }

        await call(peer: "peer-1", onSuccess: {})
        await call(peer: "peer-1", onSuccess: {})

        let runCount = await runs.value
        XCTAssertEqual(runCount, 2, "in-flight entry must be cleared once the run finishes")
    }

    /// A failing run must propagate failure to every coalesced caller, not just the first.
    func testFailure_PropagatesToAllCoalescedCallers() async {
        let gate = AsyncGate()
        service.proactiveInitOverrideForTests = { _ in
            await gate.wait()
            return false
        }

        let failures = Counter()
        async let a: Void = call(peer: "peer-1", onSuccess: {}, onFailure: { await failures.increment() })
        async let b: Void = call(peer: "peer-1", onSuccess: {}, onFailure: { await failures.increment() })

        try? await Task.sleep(nanoseconds: 120_000_000)
        await gate.open()
        _ = await (a, b)

        let failureCount = await failures.value
        XCTAssertEqual(failureCount, 2, "both callers must see the shared failure")
    }

    // MARK: - Helpers

    private func call(
        peer: String,
        onSuccess: @escaping () async -> Void,
        onFailure: @escaping () async -> Void = {}
    ) async {
        await service.initializeSessionProactively(
            userId: peer,
            onSuccess: { Task { await onSuccess() } },
            onFailure: { _ in Task { await onFailure() } }
        )
        // Callbacks hop through a Task; let them land before the assertions read the counters.
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

// MARK: - Test primitives

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// One-shot gate: `wait()` suspends until `open()` is called (or returns immediately if
/// already open), so a test can hold an in-flight run open while other callers pile up.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
