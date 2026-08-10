//
//  UnstructuredWaitTests.swift
//  ConstructMessengerTests
//
//  2026-08-10, device log: a QUIC stream open with a 1.5s soft accept timeout and a 5.0s hard one
//  took 31740ms to fail over.
//
//      07:34:13  openStream transport=QUIC → ams.konstruct.cc:443
//      07:34:43  QUIC recv pump error: Transport("recv_response: Connection error: Timeout")
//      07:34:44  MessageStream open timed out — reconnecting
//      07:34:44  MessageStream reconnecting in 1.7s (attempt #1, took 31740ms)
//
//  Both timeout racers fired on schedule. They could not leave the task group, because a sibling
//  child was parked on `try await streamTask.value` — which ignores its own cancellation — and a
//  group returns only once every child has completed. The configured timeout and the observed
//  timeout were different numbers for 29 seconds and nothing said so.
//
//  These tests are written against the shape rather than against MessageStreamManager: the defect
//  is in how a group is composed, and it reproduces in eight lines with no network.
//
//  NOT COVERED: that `openStream` actually calls this. `openStream` is a 400-line @MainActor
//  method over a gRPC client, a QUIC channel and four singletons; nothing here would notice if
//  someone put the bare `try await streamTask.value` back. What answers it is one line in a device
//  log — the failover latency the timeout claims to enforce:
//
//      MessageStream reconnecting in 1.7s (attempt #1, took 31740ms)
//
//  On a network where the direct path is blocked, "took" should now read roughly the accept
//  timeout (1.5s H3 / 2.0s H2 / 20s VEIL) plus the fetch cap, not tens of seconds. A five-figure
//  "took" against a four-second budget means this wiring came undone again.
//

import XCTest
@testable import Construct_Messenger

final class UnstructuredWaitTests: XCTestCase {

    private struct AcceptTimeout: Error {}
    private struct StreamFailed: Error {}

    /// How long a never-finishing task stands in for a QUIC connection that quinn will not give up
    /// on. Long enough that a regression is unambiguous, short enough not to stall the suite.
    private let stubbornTaskSeconds: Double = 3.0
    private let timeoutRacerSeconds: Double = 0.3

    // MARK: - The incident

    func testAcceptTimeoutLeavesTheGroupWithoutWaitingForTheStuckStream() async throws {
        let stuckStream = Task<Void, Error> { try? await Task.sleep(for: .seconds(stubbornTaskSeconds)) }
        defer { stuckStream.cancel() }

        let start = Date()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [timeoutRacerSeconds] in
                    try await Task.sleep(for: .seconds(timeoutRacerSeconds))
                    throw AcceptTimeout()
                }
                group.addTask { try await UnstructuredWait.value(of: stuckStream) }
                _ = try await group.next()
                group.cancelAll()
            }
            XCTFail("the timeout racer should have thrown")
        } catch is AcceptTimeout {
            let elapsed = Date().timeIntervalSince(start)
            // The bug produced `stubbornTaskSeconds` here. Assert against the racer, not the stub,
            // so the test states the requirement rather than the symptom.
            XCTAssertLessThan(
                elapsed, timeoutRacerSeconds + 1.0,
                "the accept timeout was pinned to the stuck stream's lifetime — this is the 31740ms failover"
            )
        }
    }

    func testTheStuckStreamSurvivesTheGroupItNoLongerBlocks() async throws {
        // Walking away from the wait must not be a statement about the work. openStream tears the
        // stream down deliberately afterwards (invalidateFastUdpConnection + streamTask.cancel);
        // if the wait cancelled it implicitly, that teardown would be racing something already dead
        // and the QUIC/H2 distinction in the catch block would stop meaning anything.
        let finished = Sentinel()
        let stream = Task<Void, Error> {
            try? await Task.sleep(for: .seconds(0.4))
            await finished.mark()
        }
        defer { stream.cancel() }

        let waiter = Task { try await UnstructuredWait.value(of: stream) }
        try await Task.sleep(for: .seconds(0.1))
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("a cancelled wait must report cancellation")
        } catch is CancellationError {
            // expected
        }

        try await Task.sleep(for: .seconds(0.6))
        let didFinish = await finished.value
        XCTAssertTrue(didFinish, "the awaited task was cancelled by its observer walking away")
    }

    // MARK: - What must NOT happen

    func testASuccessfulAcceptIsNotTornDownByCancelAll() async throws {
        // The success path calls group.cancelAll() while the stream is healthy and about to be
        // awaited for its whole lifetime. If the group's wait cancelled the stream, every
        // successful connect would immediately kill itself — a far worse failure than the one
        // being fixed, and one that would look like a server problem.
        let streamWasCancelled = Sentinel()
        let stream = Task<Void, Error> {
            do { try await Task.sleep(for: .seconds(0.5)) }
            catch { await streamWasCancelled.mark(); throw error }
        }
        defer { stream.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { return }                                        // "accepted"
            group.addTask { try await UnstructuredWait.value(of: stream) }
            _ = try await group.next()
            group.cancelAll()
        }

        try await Task.sleep(for: .seconds(0.1))
        let cancelled = await streamWasCancelled.value
        XCTAssertFalse(cancelled, "cancelAll() reached through the wait and killed an accepted stream")
    }

    func testAStreamFailingBeforeAcceptStillSurfacesItsError() async throws {
        // The child exists to fail fast when the stream dies before it is accepted. Making the
        // wait cancellable must not turn a real transport error into a silent timeout — the
        // router classifies these two differently (stream-fail vs accept_timeout).
        let stream = Task<Void, Error> {
            try await Task.sleep(for: .seconds(0.05))
            throw StreamFailed()
        }

        do {
            _ = try await UnstructuredWait.value(of: stream)
            XCTFail("the stream's error should propagate")
        } catch is StreamFailed {
            // expected
        }
    }

    func testAnAlreadyFinishedTaskReturnsItsValue() async throws {
        let done = Task<Int, Error> { 7 }
        _ = try? await done.value
        let value = try await UnstructuredWait.value(of: done)
        XCTAssertEqual(value, 7)
    }

    // MARK: - The cancelling variant

    func testCancellingVariantTearsDownTheStreamItOwns() async throws {
        // Used where openStream awaits a live stream: cancelling openStream means "tear this down".
        let streamWasCancelled = Sentinel()
        let stream = Task<Void, Error> {
            do { try await Task.sleep(for: .seconds(2.0)) }
            catch { await streamWasCancelled.mark(); throw error }
        }

        let waiter = Task { try await UnstructuredWait.cancellingValue(of: stream) }
        try await Task.sleep(for: .seconds(0.1))
        waiter.cancel()
        _ = try? await waiter.value

        try await Task.sleep(for: .seconds(0.1))
        let cancelled = await streamWasCancelled.value
        XCTAssertTrue(cancelled, "cancellingValue must propagate cancellation into the task")
    }

    // MARK: -

    private actor Sentinel {
        private(set) var value = false
        func mark() { value = true }
    }
}
