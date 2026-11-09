//
//  MailboxGapNotice.swift
//  Construct Messenger
//
//  The server's queue keeps messages for a limited time and count; when this device comes back
//  later than that, what it trimmed is gone. The server says so (`MailboxGap`, on a fetch and on
//  the stream) and the person is told with one notice above the chat list until they close it
//  (construct-docs decisions/mailbox-gap-is-reported.md, TODO 79). Whose messages they were
//  nobody knows — the server only knows the interval.
//
//  The rule is the core's (`MailboxGapState`, construct-rules `mailbox_gap`), one for every
//  client: it keeps the server's reports, open and closed, and a report the person closed does not
//  raise the notice again — the server repeats it on every stream until the cursor moves (todo
//  290). This class only holds that state for the UI, keeps its bytes (a CFE envelope) in the
//  account's key-value store, and shows its interval. Until 2026-11-09 the rule was written here
//  in Swift, twice over (dates only, then reports as JSON); `decisions/client-rules-shared-in-rust.md`.
//

import Foundation
import Observation

@MainActor
@Observable
final class MailboxGapNotice {

    static let shared = MailboxGapNotice()

    /// What the notice says: from the last position this device had to where delivery resumed;
    /// `until` nil when the mailbox held nothing at all to resume from.
    struct Interval: Equatable, Sendable {
        var from: Date
        var until: Date?
    }

    /// Read through `LocalRepositories.keyValue`, so it goes with the account's store. The bytes
    /// are the core's (`MailboxGapState.toBytes`).
    nonisolated static let key = "construct.mailboxGap.v3"
    /// Before the rule moved to the core: v1 kept dates, v2 the reports as JSON (#490). v2 is read
    /// once into the core's state, until `legacyJSONUntil`; v1 cannot tell a closed report from a
    /// new one and is dropped.
    nonisolated static let legacyKeys = ["construct.mailboxGap.v1", "construct.mailboxGap.v2"]

    /// 2027-01-31: after it `load` stops reading v2 JSON (rule 11); `MailboxGapNoticeTests`
    /// fails on that day until the reading is removed.
    nonisolated static let legacyJSONUntil = Date(timeIntervalSince1970: 1_801_353_600)

    /// The rule's state; `interval` mirrors it for observation.
    @ObservationIgnored private var state: MailboxGapState

    private(set) var interval: Interval?

    private init() {
        state = Self.load()
        interval = Self.shown(by: state)
        NotificationCenter.default.addObserver(forName: .localStoreReplaced, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let shared = MailboxGapNotice.shared
                shared.state = Self.load()
                shared.interval = Self.shown(by: shared.state)
            }
        }
    }

    /// What the server reported, from any thread.
    nonisolated static func record(afterCursor: String, resumesAt: String) {
        Task { @MainActor in shared.take(afterCursor: afterCursor, resumesAt: resumesAt) }
    }

    func dismiss() {
        state.close()
        changed()
    }

    private func take(afterCursor: String, resumesAt: String) {
        guard state.record(afterCursor: afterCursor, resumesAt: resumesAt) else {
            Log.debug("Mailbox gap reported again: \(afterCursor) — already shown or closed", category: "MessageStream")
            return
        }
        Log.info("Mailbox gap reported: \(afterCursor) → \(resumesAt.isEmpty ? "nothing held" : resumesAt)", category: "MessageStream")
        changed()
    }

    private func changed() {
        interval = Self.shown(by: state)
        do {
            try LocalRepositories.keyValue.put(Self.key, try state.toBytes())
        } catch {
            Log.error("Mailbox gap notice not kept: \(error)", category: "MessageStream")
        }
    }

    nonisolated private static func shown(by state: MailboxGapState) -> Interval? {
        state.interval().map {
            Interval(
                from: Date(timeIntervalSince1970: TimeInterval($0.fromMs) / 1000),
                until: $0.untilMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            )
        }
    }

    // MARK: - Kept state

    private static func load() -> MailboxGapState {
        if let kept = try? LocalRepositories.keyValue.get(key) {
            return MailboxGapState.fromBytes(kept: kept)
        }
        let state = MailboxGapState()
        if let v2 = try? LocalRepositories.keyValue.get(legacyKeys[1]),
           let reports = try? JSONDecoder().decode(LegacyReports.self, from: v2) {
            // The closed reports, a close, then the open ones: the core's state is the one v2 kept.
            // JSON by rule 6's exception — an earlier build's format, read once.
            for report in reports.closed {
                _ = state.record(afterCursor: report.afterCursor, resumesAt: report.resumesAt)
            }
            state.close()
            for report in reports.open {
                _ = state.record(afterCursor: report.afterCursor, resumesAt: report.resumesAt)
            }
            if let bytes = try? state.toBytes() {
                try? LocalRepositories.keyValue.put(key, bytes)
            }
        }
        for legacy in legacyKeys {
            try? LocalRepositories.keyValue.remove(legacy)
        }
        return state
    }

    /// v2 as #490 wrote it — read only, to move it into the core's state.
    private struct LegacyReports: Decodable {
        struct Report: Decodable {
            var afterCursor: String
            var resumesAt: String
        }
        var open: [Report]
        var closed: [Report]
    }
}
