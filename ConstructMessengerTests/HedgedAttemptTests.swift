//
//  HedgedAttemptTests.swift
//  ConstructMessengerTests
//

import Network
import os
import XCTest
@testable import Construct_Messenger

/// A silent first attempt gets a second beside it; the first answer wins and the other is let go.
final class HedgedAttemptTests: XCTestCase {
    private struct Refused: Error, Equatable { let index: Int }

    private actor Record {
        var started: [Int] = []
        var cancelled: [Int] = []
        var discarded: [Int] = []
        func start(_ i: Int) { started.append(i) }
        func cancel(_ i: Int) { cancelled.append(i) }
        func discard(_ i: Int) { discarded.append(i) }
    }

    /// Never answers until cancelled.
    private static func silent(_ i: Int, _ record: Record) async throws -> Int {
        do { try await Task.sleep(for: .seconds(60)) } catch { await record.cancel(i); throw error }
        return i
    }

    /// An attempt that answers before the delay is alone. Mutation: start the second at once.
    func testAnAnswerBeforeTheDelayIsTheOnlyAttempt() async throws {
        let record = Record()
        let value = try await HedgedAttempt.first(after: .seconds(30), discard: { _ in }) { i in
            await record.start(i)
            return i
        }
        XCTAssertEqual(value, 0)
        let started = await record.started
        XCTAssertEqual(started, [0])
    }

    /// Silence: the second attempt's answer is taken and the first is cancelled, not waited for.
    /// Mutations: never start the second; do not cancel the loser (the call takes a minute).
    func testASilentFirstAttemptIsReplacedByTheSecondAndCancelled() async throws {
        let record = Record()
        let began = ContinuousClock.now
        let value = try await HedgedAttempt.first(after: .milliseconds(20), discard: { _ in }) { i in
            await record.start(i)
            return i == 0 ? try await Self.silent(i, record) : i
        }
        XCTAssertEqual(value, 1)
        let (started, cancelled) = await (record.started, record.cancelled)
        XCTAssertEqual(started, [0, 1])
        XCTAssertEqual(cancelled, [0])
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5))
    }

    /// The first may still win after the second started. Mutation: drop the first's answer.
    func testALateFirstAnswerStillWins() async throws {
        let record = Record()
        let value = try await HedgedAttempt.first(after: .milliseconds(20), discard: { _ in }) { i in
            await record.start(i)
            if i == 1 { return try await Self.silent(i, record) }
            try await Task.sleep(for: .milliseconds(120))
            return i
        }
        XCTAssertEqual(value, 0)
        let cancelled = await record.cancelled
        XCTAssertEqual(cancelled, [1])
    }

    /// A failure is an answer, at once: no second attempt is made of it, and the delay is not
    /// waited out. Mutations: hedge after a failure; leave the delay running.
    func testAFailureBeforeTheDelayIsTheAnswer() async {
        let record = Record()
        let began = ContinuousClock.now
        do {
            _ = try await HedgedAttempt.first(after: .seconds(30), discard: { _ in }) { (i: Int) -> Int in
                await record.start(i)
                throw Refused(index: i)
            }
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? Refused, Refused(index: 0)) }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5))
        let started = await record.started
        XCTAssertEqual(started, [0])
    }

    /// Once both run, one failing leaves the other running; both failing fails with the first
    /// error. Mutation: throw at the first failure.
    func testOneFailureOfTwoLeavesTheOther() async throws {
        let value = try await HedgedAttempt.first(after: .milliseconds(20), discard: { _ in }) { (i: Int) -> Int in
            try await Task.sleep(for: .milliseconds(i == 0 ? 80 : 150))
            if i == 0 { throw Refused(index: 0) }
            return i
        }
        XCTAssertEqual(value, 1)

        do {
            _ = try await HedgedAttempt.first(after: .milliseconds(20), discard: { _ in }) { (i: Int) -> Int in
                try await Task.sleep(for: .milliseconds(80))
                throw Refused(index: i)
            }
            XCTFail("expected a failure")
        } catch { XCTAssertTrue(error is Refused) }
    }

    /// A loser that answers anyway is let go, not leaked. Mutation: ignore it.
    func testASecondAnswerIsDiscarded() async throws {
        let record = Record()
        let value = try await HedgedAttempt.first(
            after: .milliseconds(20),
            discard: { v in Task { await record.discard(v) } }
        ) { (i: Int) -> Int in
            // Ignores cancellation: an NWConnection that became ready as the other won.
            if i == 0 { await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value }
            return i
        }
        XCTAssertEqual(value, 1)
        try await Task.sleep(for: .milliseconds(50))
        let discarded = await record.discarded
        XCTAssertEqual(discarded, [0])
    }

    /// Cancelling the call cancels what runs. Mutation: hedge after cancellation.
    func testCancellingTheCallCancelsTheAttempts() async {
        let record = Record()
        let call = Task {
            try await HedgedAttempt.first(after: .milliseconds(200), discard: { _ in }) { i in
                await record.start(i)
                return try await Self.silent(i, record)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        call.cancel()
        _ = await call.result
        let (started, cancelled) = await (record.started, record.cancelled)
        XCTAssertEqual(started, [0])
        XCTAssertEqual(cancelled, [0])
    }

    /// Both dials end at the same moment: a front that answers nobody costs 8 s, as before.
    func testBothDialsEndTogether() {
        let d = VeilFrontExternalDialer.self
        XCTAssertEqual(d.timeout(forAttempt: 0), d.handshakeTimeout)
        XCTAssertEqual(d.silenceBeforeSecondDial + d.timeout(forAttempt: 1), d.handshakeTimeout)
    }
}

/// The dialer against a listener that accepts TCP and says nothing — the field's silent handshake.
final class VeilSilentFrontTests: XCTestCase {
    /// The second dial comes while the first is still silent, and both are given up at
    /// `handshakeTimeout`. Mutations: dial once; give the second its own 8 s.
    func testASilentFrontIsDialedTwiceAndGivenUpOnTime() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let dials = OSAllocatedUnfairLock(initialState: [(at: ContinuousClock.Instant, connection: NWConnection)]())
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            dials.withLock { $0.append((.now, c)) }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let dialer = VeilFrontExternalDialer(
            host: "127.0.0.1", port: try XCTUnwrap(listener.port?.rawValue), sni: "front.test",
            pinnedSpkiHex: String(repeating: "0", count: 64), capabilityV2B64: "", veilSkHex: "", ticketB64: "AA=="
        )
        let began = ContinuousClock.now
        do {
            _ = try await dialer.start()
            XCTFail("a silent front cannot be ready")
        } catch {}
        let took = ContinuousClock.now - began
        let at = dials.withLock { $0.map(\.at) }
        XCTAssertEqual(at.count, 2)
        if at.count == 2 {
            XCTAssertGreaterThan(at[1] - at[0], .seconds(2))
            XCTAssertLessThan(at[1] - at[0], .seconds(4.5))
        }
        XCTAssertGreaterThan(took, .seconds(7))
        XCTAssertLessThan(took, .seconds(9.5))
        // Network.framework logs the cancelled connections; let it, off this test's result line.
        try? await Task.sleep(for: .milliseconds(200))
    }
}
