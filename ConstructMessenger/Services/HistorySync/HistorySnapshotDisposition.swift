//
//  HistorySnapshotDisposition.swift
//  Construct Messenger
//
//  What is left on this side of the history projection: the id and participant rules the export
//  of a pre-CTM1 row needs. How a record meets the rows already held is the core's
//  (`history_import_*`, decisions/history-projection-in-the-core.md), as the protocol's rules
//  have been since 2026-09-29.
//

import Foundation

/// A record the store cannot take: an id missing, a body that does not map. The stream itself was
/// judged by the core; these are this app's reasons.
enum HistorySnapshotError: Error, Equatable {
    case malformed
    case unsetBody
}

enum HistorySnapshotDisposition {
    static func lowercaseMessageId(_ id: String) -> String {
        id.lowercased()
    }

    /// The two account ids a transferred message names, as dashed strings.
    ///
    /// A row's stored `fromUserId` / `toUserId` is not always an account id — older rows carry
    /// something else (empty, or a device id). The wire field is 16 bytes, and the encoder used to
    /// leave an unparseable one out; the receiver then refused the record, and a refused record
    /// ends the whole phase (a real phone's first transfer died on exactly this: `from=0B`).
    /// A side that does not parse is the one the row's role names: ours for a sent row, the
    /// chat's peer for a received one. A value that does parse is kept as stored.
    static func participants(
        storedFrom: String,
        storedTo: String,
        isSentByMe: Bool,
        ownId: String,
        chatPeerId: String?
    ) -> (from: String?, to: String?) {
        func valid(_ id: String) -> String? { HistoryAccountID.raw(id) != nil ? id : nil }
        let from = valid(storedFrom) ?? (isSentByMe ? ownId : chatPeerId)
        let to = valid(storedTo) ?? (isSentByMe ? chatPeerId : ownId)
        return (from, to)
    }
}
