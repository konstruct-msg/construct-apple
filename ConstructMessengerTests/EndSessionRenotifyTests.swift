//
//  EndSessionRenotifyTests.swift
//  ConstructMessengerTests
//
//  The teardown window is not here any more.
//
//  It was, twice over: `SessionCoordinator.endSessionSentAt` held 30 s and the core's `cooldowns`
//  held 5 s, for the same envelope to the same device. Two gates on one question, neither aware
//  of the other, and what a peer experienced was whichever noticed first. Since 2026-09-22 the
//  window is one and it is `construct-core`'s — `orchestration::session_machine`, asked through
//  `CfeIncomingEvent.teardownRequested`.
//
//  The incident this file was named for moved with it. 2026-08-11 07:19:03, two devices on a
//  network that silently dropped long-lived flows:
//
//      07:19:03  SESSION_STATE[rust_end_session]: DR diverged for ffeeddc6… — sending END_SESSION
//      07:19:03  END_SESSION sent successfully: 38eacda7-…
//      07:19:03  … messageNumber=3, eph=95ac454b… → No session for ffeeddc6
//      07:19:03  END_SESSION cooldown active for ffeeddc6…, skipping (session_out_of_sync)
//      07:19:03  … messageNumber=4 → same
//
//  The peer's log for that window contains no END_SESSION at all; its stream was down when the
//  teardown was sent and it reconnected 36 seconds later. Its own traffic was saying "I never
//  heard you", and the answer was silence for another half-minute. That is now
//  `END_SESSION_EVIDENCE_RETRY_MS` and its budget, with the Rust tests that name the mutation:
//  `evidence_buys_a_faster_retry_than_the_window`, `the_budget_runs_out_and_the_window_returns`,
//  `a_spent_budget_survives_the_window_that_spent_it`.
//
//  What is left here is the guard on the way back. A new window in the coordinator is how the
//  layer got twelve of them (`decisions/session-is-one-state-machine.md`, step 0), and the
//  decision's rule for review — "a PR with a new cooldown in the coordinator is rejected" — only
//  holds if something reads it.
//

import XCTest
@testable import Construct_Messenger

final class EndSessionWindowIsNotInTheCoordinatorTests: XCTestCase {

    private var coordinatorSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Session/SessionCoordinator.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The carriers themselves. Named, because a reader who deletes the map and leaves the
    /// constant has left the next incident somewhere to grow back from.
    ///
    /// Mutation: re-add `private var endSessionSentAt: [String: Date] = [:]` — this reddens.
    func testTheCoordinatorHoldsNoTeardownWindowOfItsOwn() {
        let source = coordinatorSource
        XCTAssertFalse(source.isEmpty, "SessionCoordinator.swift must be readable from the test bundle")

        for carrier in ["endSessionSentAt", "endSessionUnackedRetries", "endSessionCooldown"] {
            // The word may still appear in prose explaining where the window went; a declaration
            // may not.
            XCTAssertFalse(
                source.contains("var \(carrier)") || source.contains("let \(carrier)"),
                "\(carrier) is a second teardown window — the one that counts is the core's, "
                + "asked through CfeIncomingEvent.teardownRequested"
            )
        }
    }

    /// And the gate asks the core rather than a predicate. `shouldSendEndSession` is gone from
    /// `SessionReducer`; this catches a re-import of the same idea under another name.
    func testTheGateAsksTheCore() {
        let source = coordinatorSource
        guard let gate = source.range(of: "private func recordEndSessionSendIfAllowed") else {
            return XCTFail("the single teardown gate is gone — if it moved, this test moves with it")
        }
        let body = source[gate.lowerBound...].prefix(2_000)
        XCTAssertTrue(
            body.contains("teardownRequested"),
            "the gate must put the question to the machine, not answer it here"
        )
    }
}
