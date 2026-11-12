//
//  TranscriptLayoutLoopDetectorTests.swift
//  Construct MessengerTests
//
//  The detector must stay silent through any frame-paced scroll and speak once, naming the
//  fields that oscillate, when a layout feeds itself (Desktop hang, 2026-11-12).
//

import XCTest
import CoreGraphics
@testable import Construct_Messenger

final class TranscriptLayoutLoopDetectorTests: XCTestCase {

    private typealias Detector = TranscriptLayoutLoopDetector

    private func geometry(
        distance: CGFloat = 0,
        width: CGFloat = 760,
        fits: Bool = false,
        height: CGFloat = 900
    ) -> ChatScrollGeometry {
        ChatScrollGeometry(
            distanceFromBottom: distance, width: width, contentFits: fits,
            contentHeight: height, visibleMinY: 0, containerHeight: 700, safeAreaBottom: 0
        )
    }

    /// A scroll at 120 Hz for five seconds changes the geometry every frame and is not a loop: 600
    /// changes in all, never more than 121 within a second.
    ///
    /// Mutation: drop the window pruning — this reddens (600 stamps would remain).
    /// Mutation: lower `changeLimit` to 100 — this reddens.
    func testAScrollAtFrameRateIsNotReported() {
        var detector = Detector()
        for frame in 0..<600 {
            let report = detector.note(geometry(distance: CGFloat(frame)), at: Double(frame) / 120)
            XCTAssertNil(report, "frame \(frame)")
        }
        XCTAssertFalse(detector.hasReported)
    }

    /// Changes faster than any frame: reported at the limit, not one change before it.
    ///
    /// Mutation: `>=` → `>` in the limit check — the report comes one change late; this reddens.
    func testALoopIsReportedAtTheLimit() {
        var detector = Detector()
        for i in 0..<(Detector.changeLimit - 1) {
            XCTAssertNil(detector.note(geometry(width: i.isMultiple(of: 2) ? 760 : 745), at: Double(i) * 1e-5))
        }
        let report = detector.note(geometry(width: 760), at: 0.01)
        XCTAssertNotNil(report)
        XCTAssertTrue(report?.hasPrefix("TRANSCRIPT_LAYOUT_LOOP: \(Detector.changeLimit) geometry changes") ?? false,
                      report ?? "")
    }

    /// A loop that runs on writes one line, not one per change.
    ///
    /// Mutation: drop the `hasReported` guard — this reddens.
    func testALoopIsReportedOnce() {
        var detector = Detector()
        var reports = 0
        for i in 0..<(Detector.changeLimit * 3) where
            detector.note(geometry(fits: i.isMultiple(of: 2)), at: Double(i) * 1e-5) != nil {
            reports += 1
        }
        XCTAssertEqual(reports, 1)
    }

    /// The report names what oscillates, with the values it alternates between in order of first
    /// appearance, and gives the fields that held still as steady.
    ///
    /// Mutation: put every field under `changing` — this reddens.
    func testTheReportNamesTheOscillatingFieldsAndTheirValues() {
        let samples = (0..<6).map { i in
            geometry(width: i.isMultiple(of: 2) ? 760 : 745, fits: !i.isMultiple(of: 2), height: 712)
        }
        let line = Detector.describe(samples)
        XCTAssertTrue(line.contains("width{760.0,745.0}"), line)
        XCTAssertTrue(line.contains("contentFits{false,true}"), line)
        XCTAssertTrue(line.contains("steady: distanceFromBottom=0.0 contentHeight=712.0"), line)
        XCTAssertFalse(line.contains("contentHeight{"), line)
    }

    /// The report describes the latest samples only, so the values it gives are the loop's and not
    /// the opening's.
    ///
    /// Mutation: keep every sample — this reddens (the opening's width would appear).
    func testTheReportDescribesTheLatestSamples() {
        var detector = Detector()
        var report: String?
        for i in 0..<Detector.changeLimit {
            let width: CGFloat = i < 10 ? 500 : (i.isMultiple(of: 2) ? 760 : 745)
            report = detector.note(geometry(width: width), at: Double(i) * 1e-5) ?? report
        }
        XCTAssertTrue(report?.contains("width{") ?? false, report ?? "")
        XCTAssertFalse(report?.contains("500.0") ?? true, report ?? "")
    }
}
