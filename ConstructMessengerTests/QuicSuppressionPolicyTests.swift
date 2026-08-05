//
//  QuicSuppressionPolicyTests.swift
//  ConstructMessengerTests
//
//  The ladder that decides how long QUIC stays off on a network, and what a relaunch remembers.
//

import XCTest
@testable import Construct_Messenger

final class QuicSuppressionPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The ladder

    func testWindowEscalatesThenHolds() {
        XCTAssertEqual(QuicSuppressionPolicy.window(afterStrikes: 0), 300)
        XCTAssertEqual(QuicSuppressionPolicy.window(afterStrikes: 1), 3_600)
        XCTAssertEqual(QuicSuppressionPolicy.window(afterStrikes: 2), 86_400)
        // A network cannot climb past the top rung — a permanent block is still probed daily,
        // because the only alternative is never probing a network that later unblocks.
        XCTAssertEqual(QuicSuppressionPolicy.window(afterStrikes: 9), 86_400)
        XCTAssertEqual(QuicSuppressionPolicy.window(afterStrikes: -3), 300, "a corrupt count must not crash or skip rungs")
    }

    /// An unknown network gets the benefit of the doubt (one timeout can be a lost packet); a
    /// network that already proved itself does not — re-proving it is exactly the 3s tax.
    func testFailuresRequiredDependsOnWhatTheNetworkAlreadyTaughtUs() {
        XCTAssertEqual(QuicSuppressionPolicy.failuresBeforeSuppressing(strikes: 0), 2)
        XCTAssertEqual(QuicSuppressionPolicy.failuresBeforeSuppressing(strikes: 1), 1)
        XCTAssertEqual(QuicSuppressionPolicy.failuresBeforeSuppressing(strikes: 5), 1)
    }

    // MARK: - What a relaunch remembers

    func testLiveWindowIsRestoredWithItsRung() {
        let until = now.addingTimeInterval(120)
        let restored = QuicSuppressionPolicy.restore(
            persistedUntil: until, persistedStrikes: 2, sameNetwork: true, now: now
        )
        XCTAssertEqual(restored, .init(suppressedUntil: until, strikes: 2))
    }

    /// The defect this replaced: an expired window erased the record, so a permanently blocked
    /// network was rediscovered from rung zero at 3s a time, forever. Expiry is permission to
    /// probe, not permission to forget.
    func testExpiredWindowKeepsTheRung() {
        let restored = QuicSuppressionPolicy.restore(
            persistedUntil: now.addingTimeInterval(-1), persistedStrikes: 2, sameNetwork: true, now: now
        )
        XCTAssertNil(restored.suppressedUntil, "the window lapsed — QUIC must be probed again")
        XCTAssertEqual(restored.strikes, 2, "…but the next failure escalates instead of restarting")
    }

    /// Consequence of the above, stated as the behaviour a user sees: after the probe fails again,
    /// the next window is the *next* rung up, not another five minutes.
    func testProbeAfterExpiryReArmsAtTheNextRung() {
        let restored = QuicSuppressionPolicy.restore(
            persistedUntil: now.addingTimeInterval(-1), persistedStrikes: 1, sameNetwork: true, now: now
        )
        XCTAssertEqual(QuicSuppressionPolicy.window(afterStrikes: restored.strikes), 3_600)
        XCTAssertEqual(QuicSuppressionPolicy.failuresBeforeSuppressing(strikes: restored.strikes), 1,
                       "and one failure is enough to re-arm it")
    }

    /// What we learned is a claim about a network, not about the device. A different one starts clean
    /// — otherwise a day-long suppression learned behind a censored uplink would follow the user
    /// abroad and quietly hold them on the slower transport.
    func testDifferentNetworkKeepsNothing() {
        let restored = QuicSuppressionPolicy.restore(
            persistedUntil: now.addingTimeInterval(86_000), persistedStrikes: 3, sameNetwork: false, now: now
        )
        XCTAssertEqual(restored, .init(suppressedUntil: nil, strikes: 0))
    }

    func testNoRecordIsNotASuppression() {
        let restored = QuicSuppressionPolicy.restore(
            persistedUntil: nil, persistedStrikes: 0, sameNetwork: true, now: now
        )
        XCTAssertEqual(restored, .init(suppressedUntil: nil, strikes: 0))
    }

    /// A rung with no window is the normal state between probes and must survive as itself.
    func testRungWithoutWindowSurvives() {
        let restored = QuicSuppressionPolicy.restore(
            persistedUntil: nil, persistedStrikes: 2, sameNetwork: true, now: now
        )
        XCTAssertEqual(restored, .init(suppressedUntil: nil, strikes: 2))
    }

    // MARK: - Convergence

    /// The whole point, as a sequence: a network that always blocks QUIC must reach the top rung in
    /// a bounded number of probes and stay there — not pay the handshake tax on every launch.
    func testBlockedNetworkConvergesInThreeConclusions() {
        var strikes = 0
        var probes = 0
        var windows: [TimeInterval] = []
        for _ in 0..<5 {
            // Each round: the window lapses, we probe, and QUIC fails.
            probes += QuicSuppressionPolicy.failuresBeforeSuppressing(strikes: strikes)
            windows.append(QuicSuppressionPolicy.window(afterStrikes: strikes))
            strikes += 1
        }
        XCTAssertEqual(windows, [300, 3_600, 86_400, 86_400, 86_400])
        XCTAssertEqual(probes, 6, "two probes on the unknown network, one per round after")
    }
}
