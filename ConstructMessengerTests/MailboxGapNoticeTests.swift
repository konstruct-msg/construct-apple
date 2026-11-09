//
//  MailboxGapNoticeTests.swift
//  ConstructMessengerTests
//
//  The notice above the chat list when the server's queue trimmed messages this device never
//  collected (decisions/mailbox-gap-is-reported.md). The rule is the core's (construct-rules
//  `mailbox_gap`, tested and mutation-checked there); these check what this app does with it: the
//  stream's event reaches it, a closed notice stays closed through the store, the state an
//  earlier build kept moves in, and the JSON reading of that state has an end (todo 290).
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class MailboxGapNoticeTests: XCTestCase {

    /// A cursor no earlier test used, so the shared notice has never seen it.
    private func freshCursor() -> String {
        "\(UInt64(Date().timeIntervalSince1970 * 1000) + UInt64.random(in: 1...1_000_000))-0"
    }

    private func waitUntilShown() async throws {
        for _ in 0..<100 where MailboxGapNotice.shared.interval == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The stream's event reaches the notice through the real parser and the core's rule; closed,
    /// it stays closed for the same report, also as the store keeps it.
    /// Mutations that redden it: skip `record` in `MessageStreamParser`; keep v2 JSON instead of
    /// the core's bytes in `changed()`.
    func testTheStreamEventRaisesTheNoticeAndAClosedOneStaysClosed() async throws {
        MailboxGapNotice.shared.dismiss()
        let after = freshCursor()
        var gap = Shared_Proto_Services_V1_MailboxGap()
        gap.afterCursor = after
        gap.resumesAt = ""
        var response = Shared_Proto_Services_V1_MessageStreamResponse()
        response.mailboxGap = gap
        XCTAssertNil(MessageStreamParser.parse(response), "nothing to deliver")
        try await waitUntilShown()
        XCTAssertNotNil(MailboxGapNotice.shared.interval, "shown")

        MailboxGapNotice.shared.dismiss()
        XCTAssertNil(MailboxGapNotice.shared.interval)

        // What the store keeps is the core's state: read back, the same report is not news.
        let kept = try XCTUnwrap(LocalRepositories.keyValue.get(MailboxGapNotice.key))
        let state = MailboxGapState.fromBytes(kept: kept)
        XCTAssertFalse(state.record(afterCursor: after, resumesAt: ""), "closed survives the store")
        XCTAssertNil(state.interval())
    }

    /// What #490 kept as v2 JSON moves into the core's state once: closed stays closed, open stays
    /// open, and v2 is gone. Mutation that reddens it: drop the v2 branch in `load`.
    func testTheStateAnEarlierBuildKeptMovesIn() throws {
        let closed = freshCursor()
        let open = "\(UInt64(closed.dropLast(2))! + 1)-0"
        let v2 = #"{"open":[{"afterCursor":"\#(open)","resumesAt":""}],"closed":[{"afterCursor":"\#(closed)","resumesAt":""}]}"#
        try LocalRepositories.keyValue.remove(MailboxGapNotice.key)
        try LocalRepositories.keyValue.put(MailboxGapNotice.legacyKeys[1], Data(v2.utf8))

        NotificationCenter.default.post(name: .localStoreReplaced, object: nil)

        XCTAssertEqual(
            MailboxGapNotice.shared.interval?.from,
            Date(timeIntervalSince1970: TimeInterval(UInt64(open.dropLast(2))!) / 1000),
            "the open report is shown"
        )
        let state = MailboxGapState.fromBytes(kept: try XCTUnwrap(LocalRepositories.keyValue.get(MailboxGapNotice.key)))
        XCTAssertFalse(state.record(afterCursor: closed, resumesAt: ""), "the closed one stays closed")
        XCTAssertNil(try LocalRepositories.keyValue.get(MailboxGapNotice.legacyKeys[1]), "v2 is gone")
        MailboxGapNotice.shared.dismiss()
    }

    /// Rule 11: reading v2 JSON is temporary, and this fails on the day it should be gone.
    func testTheJSONReadingHasAnEnd() {
        XCTAssertLessThan(
            Date(), MailboxGapNotice.legacyJSONUntil,
            "2027-01-31 has passed: remove the v2 reading in MailboxGapNotice.load and this test"
        )
    }
}
