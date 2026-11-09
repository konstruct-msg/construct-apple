//
//  MailboxGapNoticeTests.swift
//  ConstructMessengerTests
//
//  What the person is told when the server's queue trimmed messages this device never collected
//  (decisions/mailbox-gap-is-reported.md, TODO 79), and that a notice they closed stays closed
//  while the server keeps reporting the same loss (todo 290). Canon: construct-client
//  `mailbox_gap.rs`.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class MailboxGapNoticeTests: XCTestCase {

    private typealias Report = MailboxGapNotice.Report

    private func report(_ after: String, _ resumes: String) -> Report {
        Report(afterCursor: after, resumesAt: resumes)
    }

    func testACursorNamesItsMoment() {
        XCTAssertEqual(MailboxGapNotice.date(ofCursor: "1700000000000-3"), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(MailboxGapNotice.date(ofCursor: "1700000000500"), Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertNil(MailboxGapNotice.date(ofCursor: "not-a-cursor"))
        XCTAssertNil(MailboxGapNotice.date(ofCursor: ""))
    }

    /// Nothing held to resume from: the interval is open, "since …". A report whose cursor names
    /// no moment is no notice.
    func testAnEmptyResumeIsAnOpenInterval() {
        var reports = MailboxGapNotice.Reports()
        XCTAssertTrue(reports.record(report("1700000000000-0", "")))
        XCTAssertEqual(reports.interval, .init(from: Date(timeIntervalSince1970: 1_700_000_000), until: nil))

        var garbage = MailboxGapNotice.Reports()
        XCTAssertFalse(garbage.record(report("garbage", "1700000000000-0")), "no start, no notice")
        XCTAssertNil(garbage.interval)
    }

    /// Several reports — the fetch and the stream, or two reconnects — are one notice, as wide
    /// as all of them. Mutation that reddens it: take the first report's interval only.
    func testReportsWidenTheOneNotice() {
        var reports = MailboxGapNotice.Reports()
        reports.record(report("200000-0", "300000-0"))
        reports.record(report("100000-0", "250000-0"))
        XCTAssertEqual(reports.interval, .init(from: Date(timeIntervalSince1970: 100), until: Date(timeIntervalSince1970: 300)))
        reports.record(report("150000-0", ""))
        XCTAssertNil(reports.interval?.until, "an open report keeps the notice open")
    }

    /// The owner's phone, 2026-11-09: nothing held after the cursor, so the cursor never moved and
    /// every connection reported the same loss; the closed notice came back each time.
    /// Mutation that reddens it: drop `!closed.contains(report)` from `record`.
    func testAClosedReportDoesNotComeBack() {
        var reports = MailboxGapNotice.Reports()
        let loss = report("1793460840000-0", "")
        XCTAssertTrue(reports.record(loss))
        reports.close()
        XCTAssertNil(reports.interval, "closed")

        XCTAssertFalse(reports.record(loss), "the same report on the next connection")
        XCTAssertNil(reports.interval, "stays closed")
    }

    /// A new loss after a closed one is shown. Mutation that reddens it: ignore every report once
    /// anything was closed.
    func testANewLossAfterAClosedOneIsShown() {
        var reports = MailboxGapNotice.Reports()
        reports.record(report("1793460840000-0", ""))
        reports.close()
        XCTAssertTrue(reports.record(report("1794000000000-0", "")))
        XCTAssertEqual(reports.interval?.from, Date(timeIntervalSince1970: 1_794_000_000))
    }

    /// The same report twice is one report. Mutation that reddens it: drop `!open.contains`.
    func testTheSameReportTwiceChangesNothing() {
        var reports = MailboxGapNotice.Reports()
        XCTAssertTrue(reports.record(report("1700000000000-0", "")))
        XCTAssertFalse(reports.record(report("1700000000000-0", "")))
        XCTAssertEqual(reports.open.count, 1)
    }

    /// The stream's event reaches the notice through the real parser, is kept in the account's
    /// store, and closing it keeps it closed there too.
    func testTheStreamEventRaisesTheNoticeAndClosingIsKept() async throws {
        let after = "\(UInt64(Date().timeIntervalSince1970 * 1000))-0"
        var gap = Shared_Proto_Services_V1_MailboxGap()
        gap.afterCursor = after
        gap.resumesAt = ""
        var response = Shared_Proto_Services_V1_MessageStreamResponse()
        response.mailboxGap = gap
        XCTAssertNil(MessageStreamParser.parse(response), "nothing to deliver")
        for _ in 0..<100 where !MailboxGapNotice.shared.reports.open.contains(report(after, "")) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(MailboxGapNotice.shared.reports.open.contains(report(after, "")))
        XCTAssertNotNil(try LocalRepositories.keyValue.get(MailboxGapNotice.key), "kept until seen")

        MailboxGapNotice.shared.dismiss()
        XCTAssertNil(MailboxGapNotice.shared.interval)
        let stored = try XCTUnwrap(LocalRepositories.keyValue.get(MailboxGapNotice.key))
        let kept = try JSONDecoder().decode(MailboxGapNotice.Reports.self, from: stored)
        XCTAssertTrue(kept.closed.contains(report(after, "")), "closed survives a restart")
    }
}
