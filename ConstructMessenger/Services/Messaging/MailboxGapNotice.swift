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

import Foundation
import Observation

@MainActor
@Observable
final class MailboxGapNotice {

    static let shared = MailboxGapNotice()

    /// From the last position this device had to where delivery resumed; `until` nil when the
    /// mailbox held nothing at all to resume from.
    struct Interval: Codable, Equatable, Sendable {
        var from: Date
        var until: Date?
    }

    /// Read through `LocalRepositories.keyValue`, so it goes with the account's store.
    nonisolated static let key = "construct.mailboxGap.v1"

    private(set) var interval: Interval?

    private init() {
        interval = Self.load()
        NotificationCenter.default.addObserver(forName: .localStoreReplaced, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MailboxGapNotice.shared.interval = Self.load() }
        }
    }

    /// What the server reported, from any thread. Several reports widen the one notice.
    nonisolated static func record(afterCursor: String, resumesAt: String) {
        guard let reported = interval(afterCursor: afterCursor, resumesAt: resumesAt) else { return }
        Log.info("Mailbox gap reported: \(afterCursor) → \(resumesAt.isEmpty ? "nothing held" : resumesAt)", category: "MessageStream")
        Task { @MainActor in shared.merge(reported) }
    }

    func dismiss() {
        interval = nil
        try? LocalRepositories.keyValue.remove(Self.key)
    }

    func merge(_ reported: Interval) {
        let merged: Interval
        if let current = interval {
            let until: Date? = (current.until == nil || reported.until == nil)
                ? nil
                : max(current.until!, reported.until!)
            merged = Interval(from: min(current.from, reported.from), until: until)
        } else {
            merged = reported
        }
        interval = merged
        if let data = try? JSONEncoder().encode(merged) {
            try? LocalRepositories.keyValue.put(Self.key, data)
        }
    }

    // MARK: - The rule, pure

    /// A stream cursor `ms-seq` as the moment it names; nil for anything else.
    nonisolated static func date(ofCursor cursor: String) -> Date? {
        let ms = cursor.split(separator: "-", maxSplits: 1).first.flatMap { UInt64($0) }
        return ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    nonisolated static func interval(afterCursor: String, resumesAt: String) -> Interval? {
        guard let from = date(ofCursor: afterCursor) else { return nil }
        return Interval(from: from, until: date(ofCursor: resumesAt))
    }

    private static func load() -> Interval? {
        guard let data = try? LocalRepositories.keyValue.get(key) else { return nil }
        return try? JSONDecoder().decode(Interval.self, from: data)
    }
}
