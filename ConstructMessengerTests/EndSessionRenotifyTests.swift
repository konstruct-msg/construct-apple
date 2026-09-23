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

        for carrier in [
            "endSessionSentAt", "endSessionUnackedRetries", "endSessionCooldown",
            // The inbound half, gone 2026-09-22 with the second of step 2's five timers. It held
            // 20 s against the core's 30 s and answered the same question — may an END_SESSION go
            // to this device — from the other side of it. `CfeIncomingEvent.peerToreDown` opens
            // the one window now.
            "lastInboundEndSessionAt", "postEndSessionInitFailGrace",
            // The reopen half, gone 2026-09-23 with the third. The debounce waited 1.5 s for the
            // rest of the peer's flush and the map coalesced that flush into one re-init; both
            // are `REOPEN_QUIET_MS` on one phase per device. A map here again means N re-inits
            // per flush, each destroying the session the previous one built.
            "endSessionReinitTasks", "endSessionReinitDebounceNanos",
            // The last of the five, gone 2026-09-23. The natural RESPONDER's 60 s wait for a
            // rebuild that is the peer's to make — keyed by **account**, so one device's teardown
            // armed the wait for the whole person and the first sibling to answer stood it down
            // for a ratchet still dead. It is `RESPONDER_OVERRIDE_MS`, and which side waits is
            // `tie_break_role`, asked in `handle_reopen_requested`.
            "responderFallbackTasks", "responderFallbackTimeout",
        ] {
            // The word may still appear in prose explaining where the window went; a declaration
            // may not.
            XCTAssertFalse(
                source.contains("var \(carrier)") || source.contains("let \(carrier)"),
                "\(carrier) is a second teardown window — the one that counts is the core's, "
                + "asked through CfeIncomingEvent.teardownRequested"
            )
        }
    }

    /// The peer's teardown is reported to the machine, not remembered here.
    ///
    /// The delegate that receives an inbound END_SESSION is where the 20 s map was written; if
    /// the report goes missing, nothing suppresses the blind teardown that follows a failed
    /// post-reset init, and the storm the grace was added for comes back — silently, because the
    /// suppression that disappears leaves no log line of its own.
    ///
    /// Mutation: delete the `peerToreDown` call — this reddens.
    func testAnInboundTeardownIsReportedToTheMachine() {
        let source = coordinatorSource
        guard let handler = source.range(of: "receivedEndSession peer: PeerAddress") else {
            return XCTFail("the inbound END_SESSION delegate is gone — if it moved, this moves with it")
        }
        let body = source[handler.lowerBound...].prefix(2_000)
        XCTAssertTrue(
            body.contains("peerToreDown"),
            "an inbound teardown must open the machine's window; a map here is the second one"
        )
    }

    /// And the re-init the peer's teardown raises is asked for, not scheduled.
    ///
    /// The same delegate held the debounce. If the ask goes missing the natural INITIATOR simply
    /// never rebuilds, and the peer's 60 s responder fallback covers it — so the failure is a
    /// minute of silence, not an error, which is why it needs a test rather than a log line.
    ///
    /// Mutation: replace the `reopenRequested` call with a `Task.sleep` + re-init — this reddens.
    func testTheReInitIsAskedForRatherThanScheduled() {
        let source = coordinatorSource
        guard let handler = source.range(of: "receivedEndSession peer: PeerAddress") else {
            return XCTFail("the inbound END_SESSION delegate is gone — if it moved, this moves with it")
        }
        let body = source[handler.lowerBound...].prefix(3_000)
        XCTAssertTrue(
            body.contains("reopenRequested"),
            "the machine decides when the ratchet reopens; a sleep here is the debounce back"
        )
        // A call, not the word: the comment above the ask names the sleep it replaced, and the
        // neighbouring carrier test learned the same lesson — prose explaining where a thing went
        // is not the thing.
        XCTAssertFalse(
            body.contains("await Task.sleep("),
            "a delay in this delegate is a second answer to a question the machine already answers"
        )
    }

    /// And the reopen is asked for unranked: who rebuilds is the machine's to say.
    ///
    /// The branch this replaces read `isNaturalInitiator` — which asked the core's
    /// `tie_break_role`, so the ranking was never duplicated. What was duplicated is the
    /// consequence: the RESPONDER arm armed a 60 s task keyed by account, and its stand-down
    /// condition was a third reading of the phase the core already kept.
    ///
    /// Mutation: re-add a `SessionAddressing.isNaturalInitiator` branch around the ask — this
    /// reddens.
    func testTheReopenIsAskedForWithoutRankingThePairHere() {
        let source = coordinatorSource
        guard let handler = source.range(of: "receivedEndSession peer: PeerAddress") else {
            return XCTFail("the inbound END_SESSION delegate is gone — if it moved, this moves with it")
        }
        let body = source[handler.lowerBound...].prefix(3_000)
        // The call, not the word: the comment above the ask names the branch it replaced, and
        // this is the third test in this file to learn it.
        XCTAssertFalse(
            body.contains("SessionAddressing.isNaturalInitiator("),
            "the pair is ranked in handle_reopen_requested; a second ranking here is the branch "
            + "that carried the 60 s responder fallback"
        )
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
