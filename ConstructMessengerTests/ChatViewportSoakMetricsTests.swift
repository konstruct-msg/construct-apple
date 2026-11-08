//
//  ChatViewportSoakMetricsTests.swift
//  Construct Messenger
//
//  The soak that lets the lazy transcript be deleted counts two things on the UIKit one: openings
//  whose tail landed with nobody touching, and openings whose tail never did
//  (`decisions/chat-viewport-owned-inset.md`). Until 2026-11-08 neither was recorded anywhere; the
//  predicate for the second existed with no caller (todo/257).
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ChatViewportSoakMetricsTests: XCTestCase {

    private func count(_ event: MetricEvent) -> Int { PerformanceMetrics.shared.count(event: event) }

    /// A quiet opening whose geometry never reaches the tail is reported, once.
    /// Mutation: drop the report from `updateScrollOffset` — this reddens.
    func testATailThatNeverLandsIsReportedOnce() {
        let viewport = ChatViewport()
        let before = count(.viewportLastMessageMissingAfterOpen)

        for _ in 0..<6 {
            viewport.updateScrollOffset(
                distanceFromBottom: 2_000, contentFits: false,
                contentHeight: 4_000, visibleMinY: 0, messageCount: 40
            )
        }

        XCTAssertEqual(count(.viewportLastMessageMissingAfterOpen), before + 1)
    }

    /// The container saying the tail landed is a quiet opening, counted once, and then no missing
    /// tail is reported for it. Mutation: drop the count from `noteTailLanded` — this reddens.
    func testALandedTailIsAQuietOpening() {
        let viewport = ChatViewport()
        let quietBefore = count(.viewportColdOpenQuiet)
        let missingBefore = count(.viewportLastMessageMissingAfterOpen)

        viewport.noteTailLanded()
        viewport.noteTailLanded()
        for _ in 0..<6 {
            viewport.updateScrollOffset(
                distanceFromBottom: 0, contentFits: false,
                contentHeight: 4_000, visibleMinY: 3_200, messageCount: 40
            )
        }

        XCTAssertEqual(count(.viewportColdOpenQuiet), quietBefore + 1)
        XCTAssertEqual(count(.viewportLastMessageMissingAfterOpen), missingBefore)
    }

    /// Someone took the transcript over before it landed: neither a quiet opening nor a missing
    /// tail. Mutation: count a touched opening as quiet — this reddens.
    func testATouchedOpeningCountsAsNeither() {
        let viewport = ChatViewport()
        let quietBefore = count(.viewportColdOpenQuiet)
        let missingBefore = count(.viewportLastMessageMissingAfterOpen)

        viewport.noteUserInteraction()
        viewport.noteTailLanded()
        for _ in 0..<6 {
            viewport.updateScrollOffset(
                distanceFromBottom: 2_000, contentFits: false,
                contentHeight: 4_000, visibleMinY: 0, messageCount: 40
            )
        }

        XCTAssertEqual(count(.viewportColdOpenQuiet), quietBefore)
        XCTAssertEqual(count(.viewportLastMessageMissingAfterOpen), missingBefore)
    }

    /// Testers run the UIKit transcript; the App Store does not.
    /// Mutation: default it off — this reddens in the test host, a Debug build.
    func testDebugAndBetaRunTheUIKitTranscriptByDefault() {
        XCTAssertEqual(ChatViewportConfiguration.defaultValue, AppConstants.isNonProductionBuild)
        XCTAssertTrue(ChatViewportConfiguration.defaultValue, "the test host is a Debug build")
    }
}
