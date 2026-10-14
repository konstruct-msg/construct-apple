//
//  MailboxGapNoticeTests.swift
//  ConstructMessengerTests
//
//  What the person is told when the server's queue trimmed messages this device never collected
//  (decisions/mailbox-gap-is-reported.md, TODO 79).
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class MailboxGapNoticeTests: XCTestCase {

    override func setUp() async throws {
        MailboxGapNotice.shared.dismiss()
    }

    override func tearDown() async throws {
        MailboxGapNotice.shared.dismiss()
    }

    func testACursorNamesItsMoment() {
        XCTAssertEqual(MailboxGapNotice.date(ofCursor: "1700000000000-3"), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(MailboxGapNotice.date(ofCursor: "1700000000500"), Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertNil(MailboxGapNotice.date(ofCursor: "not-a-cursor"))
        XCTAssertNil(MailboxGapNotice.date(ofCursor: ""))
    }

    /// Nothing held to resume from: the interval is open, "since …".
    func testAnEmptyResumeIsAnOpenInterval() {
        let open = MailboxGapNotice.interval(afterCursor: "1700000000000-0", resumesAt: "")
        XCTAssertEqual(open, .init(from: Date(timeIntervalSince1970: 1_700_000_000), until: nil))
        XCTAssertNil(MailboxGapNotice.interval(afterCursor: "garbage", resumesAt: "1700000000000-0"),
                     "no start, no notice")
    }

    /// Several reports — the fetch and the stream, or two reconnects — are one notice, as wide
    /// as all of them.
    func testReportsWidenTheOneNotice() {
        let notice = MailboxGapNotice.shared
        notice.merge(.init(from: Date(timeIntervalSince1970: 200), until: Date(timeIntervalSince1970: 300)))
        notice.merge(.init(from: Date(timeIntervalSince1970: 100), until: Date(timeIntervalSince1970: 250)))
        XCTAssertEqual(notice.interval, .init(from: Date(timeIntervalSince1970: 100), until: Date(timeIntervalSince1970: 300)))
        notice.merge(.init(from: Date(timeIntervalSince1970: 150), until: nil))
        XCTAssertEqual(notice.interval?.until, nil, "an open report keeps the notice open")
    }

    func testClosingRemovesItForGood() throws {
        MailboxGapNotice.shared.merge(.init(from: Date(timeIntervalSince1970: 100), until: nil))
        XCTAssertNotNil(try LocalRepositories.keyValue.get(MailboxGapNotice.key), "kept until seen")
        MailboxGapNotice.shared.dismiss()
        XCTAssertNil(MailboxGapNotice.shared.interval)
        XCTAssertNil(try LocalRepositories.keyValue.get(MailboxGapNotice.key))
    }

    /// The stream's event reaches the notice through the real parser.
    func testTheStreamEventRaisesTheNotice() async throws {
        var gap = Shared_Proto_Services_V1_MailboxGap()
        gap.afterCursor = "1700000000000-0"
        gap.resumesAt = "1700000600000-0"
        var response = Shared_Proto_Services_V1_MessageStreamResponse()
        response.mailboxGap = gap
        XCTAssertNil(MessageStreamParser.parse(response), "nothing to deliver")
        for _ in 0..<100 where MailboxGapNotice.shared.interval == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(MailboxGapNotice.shared.interval,
                       .init(from: Date(timeIntervalSince1970: 1_700_000_000), until: Date(timeIntervalSince1970: 1_700_000_600)))
    }
}
