//
//  RecoveryReminderTests.swift
//  ConstructMessengerTests
//
//  When the chat list asks for the recovery-key copy, and when it says the phrase is gone
//  (`RecoveryReminder.decide`, slice S2). Each test names the mutation that reddens it.
//

import XCTest
@testable import Construct_Messenger

final class RecoveryReminderTests: XCTestCase {

    private let made = Date(timeIntervalSince1970: 1_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func decide(
        after days: Double,
        silent: Bool = true,
        copied: Bool = false,
        phrase: RecoveryPhrasePresence = .present,
        snoozedFor days2: Double? = nil
    ) -> RecoveryReminder {
        RecoveryReminder.decide(
            now: made.addingTimeInterval(days * day),
            silentAt: silent ? made : nil,
            copied: copied,
            phrase: phrase,
            snoozedUntil: days2.map { made.addingTimeInterval($0 * day) }
        )
    }

    /// Mutation: drop the delay — the reminder shows the minute the key is made.
    func testTheFirstDaysAreQuiet() {
        XCTAssertEqual(decide(after: 0), .none)
        XCTAssertEqual(decide(after: 2.9), .none)
        XCTAssertEqual(decide(after: 3), .backupDue)
    }

    func testACopiedKeyIsNeverMentioned() {
        XCTAssertEqual(decide(after: 30, copied: true), .none)
        XCTAssertEqual(decide(after: 30, copied: true, phrase: .absent), .none)
    }

    /// A key set up through the visible flow was copied there; no silent mark, nothing to ask.
    func testAKeyNotMadeSilentlyIsNeverMentioned() {
        XCTAssertEqual(decide(after: 30, silent: false, phrase: .absent), .none)
    }

    func testClosingTheReminderQuietsItForTheSameDelay() {
        XCTAssertEqual(decide(after: 4, snoozedFor: 7), .none)
        XCTAssertEqual(decide(after: 7, snoozedFor: 7), .backupDue)
    }

    /// The phrase is gone before the copy — said at once, not after the delay.
    func testALostPhraseIsSaidAtOnce() {
        XCTAssertEqual(decide(after: 0.5, phrase: .absent), .phraseLost)
    }

    /// Mutation: treat `.unknown` like `.absent` — a locked Keychain tells the person their key is
    /// gone. That must never happen.
    func testAnUnknownAnswerIsNeverReadAsLost() {
        XCTAssertEqual(decide(after: 0.5, phrase: .unknown), .none)
        XCTAssertEqual(decide(after: 5, phrase: .unknown), .backupDue)
    }

    func testTheMarksBelongToTheirAccount() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecoveryReminderTests"))
        defaults.removePersistentDomain(forName: "RecoveryReminderTests")
        defer { defaults.removePersistentDomain(forName: "RecoveryReminderTests") }
        let marks = RecoveryBackupMarks(defaults: defaults)

        marks.markSilent(account: "u1", at: made)
        XCTAssertEqual(marks.silentAt(account: "u1"), made)
        XCTAssertNil(marks.silentAt(account: "u2"))
        XCTAssertFalse(marks.copied)
        marks.markCopied()
        XCTAssertTrue(marks.copied)
        marks.snooze(from: made)
        XCTAssertEqual(marks.snoozedUntil, made.addingTimeInterval(RecoveryReminder.delay))
    }
}
