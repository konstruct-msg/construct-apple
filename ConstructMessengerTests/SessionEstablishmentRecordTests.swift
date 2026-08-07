//
//  SessionEstablishmentRecordTests.swift
//  ConstructMessengerTests
//
//  Build 585, device 6bf51980 — the log line that exposed the hole:
//
//      10:54:00  SESSION_STATE[rust_end_session]: DR diverged for 0a1c609f… — sending END_SESSION
//      10:54:07  SESSION_STATE[proactive_init_success]: userId=0a1c609f…
//      10:54:07  SESSION_STATE[sri_sent]: to 0a1c609f… (attempt 1)
//      10:54:07  SESSION_STATE[end_session_stale_check]: 0a1c609f… ts=1786100043 established=nil
//                hasLiveSession=true → not filtered — live session will be reset
//
//  `established=nil` on a live session: as INITIATOR we built a session and recorded nothing,
//  because `markActive` only runs when the peer's `session_ready` comes back. Between creating a
//  session and being confirmed, the stale-check was disabled — for ANY inbound END_SESSION,
//  including one redelivered from hours ago, which is the case it was written for.
//
//  READ THIS BEFORE ASSUMING THE INCIDENT IS CLOSED: it is not. ts=1786100043 is 10:54:03 and the
//  session was built at 10:54:07 — a four-second crossing, inside the five-second clock-skew
//  tolerance the predicate must allow because `timestamp` comes from the peer's clock. The record
//  restores the filter for the gaps it can actually judge; a four-second crossing is not one of
//  them and needs an epoch on END_SESSION, which the wire format does not carry.
//  `testFourSecondCrossingIsStillNotResolved` pins that limit so nobody has to rediscover it.
//

import XCTest
@testable import Construct_Messenger

final class SessionEstablishmentRecordTests: XCTestCase {

    private let peer = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

    /// Real timestamps from the incident.
    private let sessionBuiltAt: UInt64        = 1_786_100_047   // 10:54:07, proactive_init_success
    private let crossingEndSessionAt: UInt64  = 1_786_100_043   // 10:54:03, the peer's teardown
    private let previousSessionAt: UInt64     = 1_786_093_336   // 09:02, the session before it
    private let fudge: UInt64 = 5                               // endSessionStaleFudge

    private var recorded: [String: UInt64] = [:]

    override func setUp() {
        super.setUp()
        recorded = [:]
        SessionEstablishment.store = SessionEstablishment.Store(
            save: { [self] at, userId in recorded[userId] = at },
            load: { [self] userId in recorded[userId] },
            clear: { [self] userId in recorded.removeValue(forKey: userId) }
        )
    }

    override func tearDown() {
        SessionEstablishment.store = .keychain
        super.tearDown()
    }

    private func isStale(_ endSessionAt: UInt64) -> Bool {
        SessionReducer.isEndSessionStale(
            establishedAt: SessionEstablishment.loadTimestamp(for: peer),
            timestamp: endSessionAt,
            fudgeSeconds: fudge
        )
    }

    // MARK: - What the record actually restores

    func testAnInitiatorSessionIsDatableBeforeThePeerConfirmsIt() {
        // The fix: `initializeSession` records here. Before it, this was nil until `session_ready`.
        SessionEstablishment.record(for: peer, at: sessionBuiltAt)
        XCTAssertEqual(SessionEstablishment.loadTimestamp(for: peer), sessionBuiltAt)
    }

    func testARedeliveredEndSessionFromThePreviousSessionIsFiltered() {
        // The storm case: an END_SESSION belonging to the 09:02 session arrives after we rebuilt at
        // 10:54:07. Nearly two hours apart — far outside any skew — and it must not tear down the
        // new session. With `established=nil` it did.
        SessionEstablishment.record(for: peer, at: sessionBuiltAt)
        XCTAssertTrue(isStale(previousSessionAt))
    }

    func testWithoutARecordEvenATwoHourOldEndSessionIsActedOn() {
        // The shipped behaviour this change removes: no record, no filter, at any age.
        XCTAssertFalse(isStale(previousSessionAt))
    }

    // MARK: - The limit, stated

    func testFourSecondCrossingIsStillNotResolved() {
        // The build-585 incident itself. `timestamp + fudge < establishedAt` is
        // 1786100043 + 5 < 1786100047 → false, so the crossing teardown is still acted on.
        // This is NOT an oversight to be fixed by widening the fudge: the tolerance exists because
        // `timestamp` is the peer's clock, and widening it starts discarding genuine teardowns.
        // Settling a crossing needs END_SESSION to name the session it condemns.
        SessionEstablishment.record(for: peer, at: sessionBuiltAt)
        XCTAssertFalse(
            isStale(crossingEndSessionAt),
            "if this ever goes true, the fudge was widened — check what genuine teardowns it now eats"
        )
    }

    // MARK: - What must NOT be filtered
    //
    // Suppressing a real teardown is worse than the bug: both sides keep ratcheting apart in
    // silence, with no END_SESSION left to notice.

    func testAGenuineEndSessionAfterEstablishmentIsStillActedOn() {
        SessionEstablishment.record(for: peer, at: sessionBuiltAt)
        XCTAssertFalse(isStale(sessionBuiltAt + 30))
    }

    func testAnEndSessionInsideTheClockSkewWindowIsStillActedOn() {
        SessionEstablishment.record(for: peer, at: sessionBuiltAt)
        XCTAssertFalse(isStale(sessionBuiltAt - 1))
    }

    // MARK: - The record's own contract

    func testTeardownClearsTheRecordSoTheNextSessionIsNotDatedByTheOldOne() {
        SessionEstablishment.record(for: peer, at: sessionBuiltAt)
        SessionEstablishment.clear(for: peer)
        XCTAssertNil(SessionEstablishment.loadTimestamp(for: peer))
    }

    func testReInitOverwritesTheEarlierRecord() {
        SessionEstablishment.record(for: peer, at: previousSessionAt)
        SessionEstablishment.record(for: peer, at: sessionBuiltAt)
        XCTAssertEqual(SessionEstablishment.loadTimestamp(for: peer), sessionBuiltAt)
    }

    func testAnEmptyUserIdIsNotRecorded() {
        SessionEstablishment.record(for: "", at: sessionBuiltAt)
        XCTAssertNil(SessionEstablishment.loadTimestamp(for: ""))
    }

    // NOT COVERED: that `SessionInitializationService.initializeSession` actually calls
    // `SessionEstablishment.record`. Reaching it from a test needs a real crypto core and a real
    // pre-key bundle. The line that answers it on device is the stale-check itself — after this
    // change `SESSION_STATE[end_session_stale_check]` for a freshly re-initialised peer must read
    // `established=<timestamp>`, never `established=nil hasLiveSession=true`.
}
