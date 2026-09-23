//
//  ServerMessageOrder.swift
//  Construct Messenger
//
//  One sortable representation of the server's total message order.
//

import Foundation

/// The transport order is `(server millisecond, sequence)`, not the sender's wall clock.
/// Core Data stores the fixed-width string so its ordinary lexicographic sort has the same
/// result as numeric comparison without packing two independently-sized values into one Int64.
enum ServerMessageOrder {
    private static let componentWidth = 20
    private static let separator: Character = "-"
    private static let pendingTimestamp = String(repeating: "9", count: componentWidth)
    private static let pendingSequence = String(repeating: "9", count: componentWidth)

    /// Canonical key from a Redis stream cursor (`serverMs-seq`).
    static func key(cursor: String) -> String? {
        let parts = cursor.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: true)
        guard let timestamp = parts.first.flatMap({ UInt64($0) }) else { return nil }
        let sequence = parts.dropFirst().first.flatMap { UInt64($0) } ?? 0
        return key(serverTimestampMilliseconds: timestamp, sequence: sequence)
    }

    /// Canonical key from server metadata or a send acknowledgement.
    static func key(serverTimestampMilliseconds: Int64, sequence: UInt64) -> String? {
        guard serverTimestampMilliseconds > 0 else { return nil }
        return key(serverTimestampMilliseconds: UInt64(serverTimestampMilliseconds), sequence: sequence)
    }

    /// Returns a key using the envelope's server metadata, falling back to the stream cursor when
    /// an older server did not populate `server_metadata` yet. The cursor sequence is the exact
    /// tie-breaker for the mailbox; message_number is the fallback available on send ACKs.
    static func key(
        serverTimestampMilliseconds: Int64,
        sequence: UInt64,
        cursor: String?
    ) -> String? {
        let cursorParts = cursor.flatMap(Self.components(from:))
        let timestamp = serverTimestampMilliseconds > 0
            ? UInt64(serverTimestampMilliseconds)
            : cursorParts?.timestamp
        let resolvedSequence = cursorParts?.sequence ?? sequence
        guard let timestamp else { return nil }
        return key(serverTimestampMilliseconds: timestamp, sequence: resolvedSequence)
    }

    /// A locally-created row has no server position until its send is acknowledged. Putting it
    /// after every real server key keeps the optimistic bubble at the bottom and lets it snap to
    /// its authoritative position when the ACK arrives.
    static func pending(localMessageId: String) -> String {
        "\(pendingTimestamp)\(separator)\(pendingSequence)\(separator)\(localMessageId.lowercased())"
    }

    /// A row that has no server position and never will: a locally written system notice, an
    /// imported history row, or one written before this column existed. It sits at its own
    /// displayed timestamp — unlike `pending` above, which belongs to a row that is *waiting* for
    /// a position and must stay at the bottom until the acknowledgement moves it.
    ///
    /// The message id is the third component and it is what makes the key **total**. Without it
    /// two rows in the same millisecond compare equal, every fetch falls through to its secondary
    /// descriptor — `id`, a random UUID — and the transcript orders them by coin flip. That is
    /// what let five identical "session out of sync" notices stack: the check that suppresses a
    /// repeat reads *the newest row*, and among same-millisecond rows "newest" was random.
    static func local(timestamp: Date, messageId: String) -> String {
        // Clamped to 1ms, not 0: a row at the epoch belongs at the top of a transcript, and 0 is
        // the one value `key(serverTimestampMilliseconds:)` refuses.
        let milliseconds = UInt64(max(Int64(timestamp.timeIntervalSince1970 * 1000), 1))
        return "\(padded(milliseconds))\(separator)\(padded(0))\(separator)\(messageId.lowercased())"
    }

    /// Stable comparison key for callers that sort already-loaded managed objects.
    static func effectiveKey(for message: Message) -> String {
        message.serverOrderKey ?? local(timestamp: message.safeTimestamp, messageId: message.id)
    }

    private static func key(serverTimestampMilliseconds: UInt64, sequence: UInt64) -> String {
        "\(padded(serverTimestampMilliseconds))\(separator)\(padded(sequence))"
    }

    private static func components(from cursor: String) -> (timestamp: UInt64, sequence: UInt64)? {
        let parts = cursor.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: true)
        guard let timestamp = parts.first.flatMap({ UInt64($0) }) else { return nil }
        let sequence = parts.dropFirst().first.flatMap { UInt64($0) } ?? 0
        return (timestamp, sequence)
    }

    private static func padded(_ value: UInt64) -> String {
        let decimal = String(value)
        guard decimal.count < componentWidth else { return decimal }
        return String(repeating: "0", count: componentWidth - decimal.count) + decimal
    }
}
