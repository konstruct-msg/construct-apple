//
//  MailboxGapNotice.swift
//  Construct Messenger
//
//  The server's queue keeps messages for a limited time and count; when this device comes back
//  later than that, what it trimmed is gone. The server now says so (`MailboxGap`, on a fetch
//  and once on the stream) and this keeps the interval until the person has seen it: one notice
//  above the chat list (construct-docs decisions/mailbox-gap-is-reported.md, TODO 79). Whose
//  messages they were nobody knows — the server only knows the interval.
//
//  The notice keeps the reports it was made of, not just their dates. The server reports again
//  on every stream it opens until the cursor moves, and the cursor does not move while the mailbox
//  holds nothing to deliver. Until 2026-11-09 only the dates were kept, so a closed notice came
//  back on the next connection, every time (owner's phone, "since 31 Oct 13:14"). A report the
//  person already closed is the same loss, named by the same cursors, and does not raise the
//  notice again (todo 290). Canon: construct-client `mailbox_gap.rs`.
//

import Foundation
import Observation

@MainActor
@Observable
final class MailboxGapNotice {

    static let shared = MailboxGapNotice()

    /// One report as the server made it: the cursor this device read from, and the oldest
    /// position still held (empty when nothing is).
    struct Report: Codable, Equatable, Sendable {
        var afterCursor: String
        var resumesAt: String
    }

    /// What the notice says: from the last position this device had to where delivery resumed;
    /// `until` nil when the mailbox held nothing at all to resume from.
    struct Interval: Equatable, Sendable {
        var from: Date
        var until: Date?
    }

    /// The notice as the account's store keeps it. Pure: the rule lives here.
    struct Reports: Codable, Equatable, Sendable {
        /// Reported and not yet closed.
        var open: [Report] = []
        /// Closed by the person: these again are not a new loss.
        var closed: [Report] = []

        /// Take a report in. Whether the notice changed: a report already open or already closed,
        /// or one whose cursor names no moment, changes nothing.
        mutating func record(_ report: Report) -> Bool {
            guard MailboxGapNotice.date(ofCursor: report.afterCursor) != nil,
                  !open.contains(report), !closed.contains(report) else { return false }
            open.append(report)
            return true
        }

        /// The person closed the notice. Only the reports it showed are remembered as seen: the
        /// cursor never goes back, so older closed ones cannot be reported again.
        mutating func close() {
            closed = open
            open = []
        }

        /// What is shown: one interval as wide as every open report, open-ended if any of them is.
        var interval: Interval? {
            guard let from = open.compactMap({ MailboxGapNotice.date(ofCursor: $0.afterCursor) }).min() else {
                return nil
            }
            var until: Date? = .distantPast
            for report in open {
                guard let current = until, let resumes = MailboxGapNotice.date(ofCursor: report.resumesAt) else {
                    until = nil
                    continue
                }
                until = max(current, resumes)
            }
            return Interval(from: from, until: until)
        }
    }

    /// Read through `LocalRepositories.keyValue`, so it goes with the account's store.
    nonisolated static let key = "construct.mailboxGap.v2"
    /// Dates only, before 2026-11-09: it cannot tell a closed report from a new one, so it is
    /// dropped; the next report raises the notice again, once.
    nonisolated static let legacyKey = "construct.mailboxGap.v1"

    private(set) var reports: Reports

    var interval: Interval? { reports.interval }

    private init() {
        reports = Self.load()
        NotificationCenter.default.addObserver(forName: .localStoreReplaced, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MailboxGapNotice.shared.reports = Self.load() }
        }
    }

    /// What the server reported, from any thread.
    nonisolated static func record(afterCursor: String, resumesAt: String) {
        let report = Report(afterCursor: afterCursor, resumesAt: resumesAt)
        Task { @MainActor in
            guard shared.reports.record(report) else {
                Log.debug("Mailbox gap reported again: \(afterCursor) — already shown or closed", category: "MessageStream")
                return
            }
            Log.info("Mailbox gap reported: \(afterCursor) → \(resumesAt.isEmpty ? "nothing held" : resumesAt)", category: "MessageStream")
            shared.save()
        }
    }

    func dismiss() {
        reports.close()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reports) {
            try? LocalRepositories.keyValue.put(Self.key, data)
        }
    }

    // MARK: - The rule, pure

    /// A stream cursor `ms-seq` as the moment it names; nil for anything else.
    nonisolated static func date(ofCursor cursor: String) -> Date? {
        let ms = cursor.split(separator: "-", maxSplits: 1).first.flatMap { UInt64($0) }
        return ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    private static func load() -> Reports {
        try? LocalRepositories.keyValue.remove(legacyKey)
        guard let data = try? LocalRepositories.keyValue.get(key),
              let reports = try? JSONDecoder().decode(Reports.self, from: data) else { return Reports() }
        return reports
    }
}
