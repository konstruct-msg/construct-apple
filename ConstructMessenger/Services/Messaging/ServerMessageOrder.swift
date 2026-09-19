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

    /// Legacy rows predate the server-order column. This is only a migration fallback; all new
    /// transport paths write an authoritative key or the explicit pending sentinel above.
    static func legacy(timestamp: Date, messageId: String) -> String {
        let milliseconds = max(Int64(timestamp.timeIntervalSince1970 * 1000), 0)
        return key(serverTimestampMilliseconds: milliseconds, sequence: 0)
            ?? pending(localMessageId: messageId)
    }

    /// Stable comparison key for callers that sort already-loaded managed objects.
    static func effectiveKey(for message: Message) -> String {
        message.serverOrderKey ?? legacy(timestamp: message.safeTimestamp, messageId: message.id)
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
