//
//  TokenWalletBurstTests.swift
//  ConstructMessengerTests
//
//  The gate that decides whether a send waits for tokens, whether it starts a batch, and when it
//  gives up. All of it turns on one distinction the old single `cooldownUntil` could not make:
//  pacing is a politeness we chose, back-off is the server saying no.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class TokenWalletBurstTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var future: Date { now.addingTimeInterval(60) }
    private var past: Date { now.addingTimeInterval(-60) }

    // MARK: - The defect

    /// The 93-of-271 case. Wallet empty, a batch already in flight: the send must wait for it, not
    /// walk past it token-less. Under enforce "walk past" means the server rejects the message.
    func testEmptyWalletWithBatchInFlightWaits() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 0, isReplenishing: true,
                                   pacingUntil: nil, backoffUntil: nil, now: now),
            .waitForInFlight
        )
    }

    /// Our own 90s pacing must not hold back an empty wallet. It exists to be polite to an issuer
    /// that refuses explicitly — and being polite here costs a rejected message.
    func testEmptyWalletOutranksOurOwnPacing() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 0, isReplenishing: false,
                                   pacingUntil: future, backoffUntil: nil, now: now),
            .start
        )
    }

    /// The mirror image: the issuer refused, so an empty wallet changes nothing. Re-asking inside
    /// the back-off cannot succeed, and waiting would only add latency to a doomed send.
    func testIssuerBackoffHoldsEvenWhenWalletIsEmpty() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 0, isReplenishing: false,
                                   pacingUntil: nil, backoffUntil: future, now: now),
            .blockedByBackoff
        )
    }

    // MARK: - The ordinary cases

    /// A merely *low* wallet is what pacing is for — nothing is at stake, so wait for the window.
    func testLowButNonEmptyWalletRespectsPacing() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 5, isReplenishing: false,
                                   pacingUntil: future, backoffUntil: nil, now: now),
            .blockedByPacing
        )
    }

    func testLapsedPacingAllowsABatch() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 5, isReplenishing: false,
                                   pacingUntil: past, backoffUntil: nil, now: now),
            .start
        )
    }

    func testLapsedBackoffAllowsABatch() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 0, isReplenishing: false,
                                   pacingUntil: nil, backoffUntil: past, now: now),
            .start
        )
    }

    /// In-flight outranks everything: one batch at a time is the invariant that makes the wait
    /// terminate, and a second claim would let two sends each think they started the one they wait on.
    func testInFlightOutranksBackoffAndPacing() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 0, isReplenishing: true,
                                   pacingUntil: future, backoffUntil: future, now: now),
            .waitForInFlight
        )
    }

    /// Back-off outranks pacing when both are set — it is the stronger claim, and it is the one
    /// that must not be cleared by a successful-batch timer.
    func testBackoffOutranksPacing() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 5, isReplenishing: false,
                                   pacingUntil: future, backoffUntil: future, now: now),
            .blockedByBackoff
        )
    }

    func testHealthyWalletWithNothingHeldStartsWhenAsked() {
        XCTAssertEqual(
            BlindTokenService.gate(balance: 100, isReplenishing: false,
                                   pacingUntil: nil, backoffUntil: nil, now: now),
            .start
        )
    }

    // MARK: - The burst, as a sequence

    /// What the busy hour looked like: the wallet drains, and every send after the first used to
    /// step over the empty wallet. Now only the states that can produce a token do so, and the
    /// one that cannot (issuer refusing) is the only one that still sends token-less.
    func testBurstStatesThatStillSendWithoutAToken() {
        let sendsWithoutWaiting: [ReplenishGate] = [.blockedByBackoff, .blockedByPacing]
        for balance in [0] {
            for gate in [ReplenishGate.start, .waitForInFlight, .blockedByBackoff, .blockedByPacing] {
                let reachable = BlindTokenService.gate(
                    balance: balance,
                    isReplenishing: gate == .waitForInFlight,
                    pacingUntil: gate == .blockedByPacing ? future : nil,
                    backoffUntil: gate == .blockedByBackoff ? future : nil,
                    now: now
                )
                if reachable == .blockedByPacing {
                    XCTFail("an empty wallet must never be held by pacing — that is the 93-of-271 defect")
                }
                XCTAssertTrue(
                    reachable == .start || reachable == .waitForInFlight || sendsWithoutWaiting.contains(reachable),
                    "unexpected gate \(reachable)"
                )
            }
        }
    }
}
