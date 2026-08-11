//
//  EndSessionRenotifyTests.swift
//  ConstructMessengerTests
//
//  2026-08-11, two devices on a network that silently drops long-lived flows (a laptop soak on the
//  same Wi-Fi: held-channel unary at 72 / 10005 / 10004 / 234 / 69 / 10005 ms, 12 HTTP/2 PINGs sent
//  against ~7 ACKs, and a pcap showing the server stop acknowledging ~10s into a flow with no RST
//  and no ICMP).
//
//  The receiving device tore its session down and told the peer:
//
//      07:19:03  SESSION_STATE[rust_end_session]: DR diverged for ffeeddc6… — sending END_SESSION
//      07:19:03  END_SESSION sent successfully: 38eacda7-…
//      07:19:03  Session archived / Removed from Rust core / Removed from Keychain
//      07:19:03  … messageNumber=3, eph=95ac454b… → No session for ffeeddc6
//      07:19:03  END_SESSION cooldown active for ffeeddc6…, skipping (session_out_of_sync)
//      07:19:03  … messageNumber=4 → same
//
//  The peer's log for that whole window contains no END_SESSION at all. Its stream was down when
//  the teardown was sent, and it reconnected 36 seconds later.
//
//  There is no acknowledgement for END_SESSION — nothing tells us the peer applied it. But the
//  opposite is observable: a message arriving on a session we already destroyed is proof it did
//  not. The cooldown was treating that evidence as a reason to stay quiet.
//

import XCTest
@testable import Construct_Messenger

final class EndSessionRenotifyTests: XCTestCase {

    private let cooldown: TimeInterval = 30
    private let now = Date(timeIntervalSince1970: 1_786_432_743)

    private func sent(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }

    // MARK: - The incident

    func testAPeerStillOnTheDeadSessionIsRenotifiedWithoutWaitingOutTheCooldown() {
        // messageNumber=3 arrived in the same second as the teardown. Under the plain cooldown the
        // answer was silence for another 30s, while the peer kept talking into a session that no
        // longer existed on this side.
        XCTAssertTrue(
            SessionReducer.shouldSendEndSession(
                lastSentAt: sent(SessionReducer.endSessionUnackedRetryDelay),
                now: now,
                cooldown: cooldown,
                peerStillOnDeadSession: true,
                unackedRetries: 0
            )
        )
    }

    func testTheRenotificationStillWaitsItsShortDelay() {
        // Evidence buys a faster retry, not an instant one: a burst of mid-ratchet messages
        // arrives in one second and must not become a burst of END_SESSIONs.
        XCTAssertFalse(
            SessionReducer.shouldSendEndSession(
                lastSentAt: sent(0.2),
                now: now,
                cooldown: cooldown,
                peerStillOnDeadSession: true,
                unackedRetries: 0
            )
        )
    }

    // MARK: - What must NOT happen

    func testTheRetryBudgetIsBoundedAndFallsBackToTheFullCooldown() {
        // This is the storm-prone path the cooldown exists for. After the budget, evidence stops
        // buying anything — if that many re-notifications did not land, the next one will not either.
        let exhausted = SessionReducer.endSessionMaxUnackedRetries
        XCTAssertFalse(
            SessionReducer.shouldSendEndSession(
                lastSentAt: sent(SessionReducer.endSessionUnackedRetryDelay + 1),
                now: now,
                cooldown: cooldown,
                peerStillOnDeadSession: true,
                unackedRetries: exhausted
            ),
            "an exhausted budget must obey the ordinary cooldown"
        )
        XCTAssertTrue(
            SessionReducer.shouldSendEndSession(
                lastSentAt: sent(cooldown + 1),
                now: now,
                cooldown: cooldown,
                peerStillOnDeadSession: true,
                unackedRetries: exhausted
            ),
            "…and must recover once the cooldown itself expires"
        )
    }

    func testWithoutEvidenceTheBehaviourIsUnchanged() {
        // The DR-diverge path has no evidence about the peer — it is reacting to its own state.
        // Loosening that one would reintroduce the storm this cooldown was written for.
        XCTAssertFalse(
            SessionReducer.shouldSendEndSession(
                lastSentAt: sent(5),
                now: now,
                cooldown: cooldown,
                peerStillOnDeadSession: false,
                unackedRetries: 0
            )
        )
        XCTAssertTrue(
            SessionReducer.shouldSendEndSession(
                lastSentAt: sent(cooldown),
                now: now,
                cooldown: cooldown,
                peerStillOnDeadSession: false,
                unackedRetries: 0
            )
        )
    }

    func testTheEvidencePathMatchesThePlainDecisionWhenNothingWasEverSent() {
        // A first teardown is never rate-limited, with or without evidence.
        for evidence in [true, false] {
            XCTAssertTrue(
                SessionReducer.shouldSendEndSession(
                    lastSentAt: nil,
                    now: now,
                    cooldown: cooldown,
                    peerStillOnDeadSession: evidence,
                    unackedRetries: 0
                )
            )
        }
    }

    func testTheEvidenceOverloadAgreesWithTheOriginalWhenThereIsNoEvidence() {
        // Two overloads, one rule. They drifting apart is the defect class this repo keeps paying
        // for, so pin them against each other rather than trusting the shared body.
        for elapsed in [0.0, 1.0, 3.0, 29.9, 30.0, 60.0] {
            let plain = SessionReducer.shouldSendEndSession(
                lastSentAt: sent(elapsed), now: now, cooldown: cooldown
            )
            let withFlag = SessionReducer.shouldSendEndSession(
                lastSentAt: sent(elapsed),
                now: now,
                cooldown: cooldown,
                peerStillOnDeadSession: false,
                unackedRetries: 0
            )
            XCTAssertEqual(plain, withFlag, "the overloads disagree at elapsed=\(elapsed)s")
        }
    }
}
