//
//  AckCheckOutcomeTests.swift
//  ConstructMessengerTests
//
//  An empty action list is a verdict, not a missing answer.
//
//  The core maps `RoutingDecision::Duplicate` to `vec![]` (orchestrator.rs:1669). `MessageRouter`
//  read that as "nothing came back" — `if !followup.isEmpty { actions = followup }` — so `actions`
//  kept holding the pre-round-trip `[checkAckInDb]`, and the fallthrough at the bottom logged a
//  correctly-dropped duplicate as "no routing decision … NOT acked, no row written", naming the one
//  action it had just answered. 6296 of 6302 such lines in the 2026-08-04 device run: the detector
//  built to catch silent divergence was itself reporting healthy traffic as a mystery, which is
//  what kept it at INFO and unusable for the "0 unexplained ERROR" acceptance criterion.
//
//  Empty is overloaded three ways in `decision_to_actions`: duplicate, init lock held, END_SESSION
//  cooldown. What makes this resolvable without a core change is that our OWN answer separates
//  them: `resume_after_ack_check` returns `Duplicate` on `is_processed = true` before either other
//  branch is reachable (message_router.rs:271).
//

import XCTest
@testable import Construct_Messenger

final class AckCheckOutcomeTests: XCTestCase {

    // MARK: - The regression

    /// The 6296-line case: we said "already processed", the core answered with the empty verdict.
    /// Terminal and benign — it must never look like an undecided message.
    func testEmptyAfterProcessedAnswerIsADuplicate() {
        XCTAssertEqual(
            AckCheckOutcome.resolve(followupIsEmpty: true, weAnsweredProcessed: true),
            .duplicate,
            "an empty list after we answered 'processed' is the core's Duplicate verdict — "
            + "treating it as 'no answer' is what made 6296 healthy drops look like defects"
        )
    }

    /// The same empty list with the opposite answer is NOT benign: the core dropped a message it
    /// had just been told was new. Distinguishing the two is the entire point of the type.
    func testEmptyAfterNotProcessedAnswerIsADrop() {
        XCTAssertEqual(
            AckCheckOutcome.resolve(followupIsEmpty: true, weAnsweredProcessed: false),
            .droppedPendingRedelivery,
            "init lock or END_SESSION cooldown — the message returns only by redelivery"
        )
    }

    /// The two empty cases must not collapse into each other in either direction.
    func testTheTwoEmptyVerdictsAreDistinct() {
        XCTAssertNotEqual(
            AckCheckOutcome.resolve(followupIsEmpty: true, weAnsweredProcessed: true),
            AckCheckOutcome.resolve(followupIsEmpty: true, weAnsweredProcessed: false),
            "same empty list, opposite meanings — collapsing them re-creates the defect with a "
            + "different symptom (a real drop counted as a routine duplicate)"
        )
    }

    // MARK: - The routable path must stay untouched

    /// A non-empty list is the core's real routing decision and must be followed, regardless of
    /// what we answered. `is_processed = false` is the ordinary path: DB confirms the message is
    /// new, the core routes it.
    func testNonEmptyAfterNotProcessedIsRoutable() {
        XCTAssertEqual(
            AckCheckOutcome.resolve(followupIsEmpty: false, weAnsweredProcessed: false),
            .routable
        )
    }

    /// The answer must not override a list the core actually returned. `Duplicate` is the core's
    /// call to make; if it hands back actions after a "processed" answer, we execute them — second-
    /// guessing the core here would strand whatever it asked for.
    func testNonEmptyAfterProcessedIsStillRoutable() {
        XCTAssertEqual(
            AckCheckOutcome.resolve(followupIsEmpty: false, weAnsweredProcessed: true),
            .routable,
            "emptiness decides the verdict; our answer only disambiguates WHICH empty verdict"
        )
    }

    /// Every combination is covered above — pinned so a future third input cannot be added
    /// without deciding what it means for both existing dimensions.
    func testAllFourCombinationsAreAccountedFor() {
        let outcomes = [
            AckCheckOutcome.resolve(followupIsEmpty: true,  weAnsweredProcessed: true),
            AckCheckOutcome.resolve(followupIsEmpty: true,  weAnsweredProcessed: false),
            AckCheckOutcome.resolve(followupIsEmpty: false, weAnsweredProcessed: true),
            AckCheckOutcome.resolve(followupIsEmpty: false, weAnsweredProcessed: false)
        ]
        XCTAssertEqual(outcomes, [.duplicate, .droppedPendingRedelivery, .routable, .routable])
    }
}
