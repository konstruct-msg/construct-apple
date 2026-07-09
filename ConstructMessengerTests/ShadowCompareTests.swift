//
//  ShadowCompareTests.swift
//  ConstructMessengerTests
//
//  Tests the shadow-mode harness (SESSION_COORDINATOR_REFACTOR_SPEC risk step #3):
//  `decide` must ALWAYS return the live value (never alter production behaviour), while
//  tallying and de-duplicating divergences so a risky cut-over can be measured first.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ShadowCompareTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ShadowCompare.reset()
    }

    override func tearDown() {
        ShadowCompare.reset()
        super.tearDown()
    }

    func testAlwaysReturnsLive_EvenWhenCandidateDiffers() {
        let result = ShadowCompare.decide("t", key: "k", live: true, candidate: false)
        XCTAssertTrue(result, "decide must return the live value regardless of the candidate")
    }

    func testAgreement_NoDivergenceRecorded() {
        _ = ShadowCompare.decide("agree", key: "k", live: 7, candidate: 7)
        XCTAssertEqual(ShadowCompare.divergences(for: "agree"), 0)
    }

    func testDivergence_IsTallied() {
        _ = ShadowCompare.decide("diff", key: "a", live: true, candidate: false)
        _ = ShadowCompare.decide("diff", key: "b", live: true, candidate: false)
        XCTAssertEqual(ShadowCompare.divergences(for: "diff"), 2,
                       "every disagreement increments the per-label tally")
    }

    func testTallyCountsEveryDivergence_EvenWhenLogDeduped() {
        // Same signature repeated → logged once, but counted every time.
        for _ in 0..<5 {
            _ = ShadowCompare.decide("dedup", key: "same", live: 1, candidate: 2)
        }
        XCTAssertEqual(ShadowCompare.divergences(for: "dedup"), 5)
    }

    func testReset_ClearsTallies() {
        _ = ShadowCompare.decide("r", key: "k", live: true, candidate: false)
        XCTAssertEqual(ShadowCompare.divergences(for: "r"), 1)
        ShadowCompare.reset()
        XCTAssertEqual(ShadowCompare.divergences(for: "r"), 0)
    }

    func testLabelsAreIsolated() {
        _ = ShadowCompare.decide("x", live: true, candidate: false)
        _ = ShadowCompare.decide("y", live: true, candidate: true)
        XCTAssertEqual(ShadowCompare.divergences(for: "x"), 1)
        XCTAssertEqual(ShadowCompare.divergences(for: "y"), 0)
    }
}
