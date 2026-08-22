//
//  ReactionReducer.swift
//  Construct Messenger
//
//  Pure apply for MessageContent.reaction. A reaction is metadata on a target
//  message, never a chat row — see MESSAGE_REACTIONS_SPEC /
//  decisions/reactions-instagram-model.md.
//
//  No I/O, no Date(), no Core Data. Timestamp is an argument so LWW is
//  deterministic in tests.
//

import Foundation

enum ReactionReducer {

    /// Instagram DM quick set. Display order is the array order. v1 is this
    /// popular set; later it can become the user's most frequent.
    static let quickSet = ["❤️", "😂", "😮", "😢", "😠", "🔥"]

    /// Double-tap target. First of `quickSet` so the fast path and the capsule agree.
    static let likeEmoji = "❤️"

    struct SendPlan: Equatable {
        let targetMessageId: String
        let incoming: Incoming
        let timestampMs: Int64
    }

    static let orphanTTLSeconds: TimeInterval = 7 * 24 * 60 * 60
    static let maxEmojiUTF8ByteCount = 32
    static let maxTargetIdLength = 64

    struct Row: Equatable {
        var emoji: String
        var timestampMs: Int64
    }

    enum Incoming: Equatable {
        case add(emoji: String)
        case remove
    }

    enum Decision: Equatable {
        /// Upsert the reactor's emoji on the target.
        case set(emoji: String, timestampMs: Int64)
        /// Delete the reactor's row on the target.
        case clear
        /// Incoming is older, a tie, or a no-op remove of a missing row. Keep what we have.
        case keepExisting
        /// Malformed payload. Still ACK the envelope so it cannot redeliver as a bubble.
        case dropInvalid
    }

    /// Field 4 `timestamp_ms`. 0 means a pre-field peer — use the injected fallback
    /// (receive time). Any positive payload clock beats a fallback-only row.
    static func normalizeTimestamp(payloadMs: Int64, fallbackMs: Int64) -> Int64 {
        payloadMs > 0 ? payloadMs : max(0, fallbackMs)
    }

    static func isValidTargetId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxTargetIdLength
    }

    /// Whether this string is an emoji we may set as a reaction.
    ///
    /// **It has to actually check that.** Until 2026-08-22 the name was the only part of this that
    /// mentioned emoji: it tested non-empty, ≤32 bytes, no newline or NUL, and returned true for
    /// everything else. Both boundaries use it, so both leaked.
    ///
    /// On the way out, the "more reactions" screen offers a text field and calls this on each typed
    /// character. The emoji keyboard is a preference iOS does not have to honour, so on device it is
    /// the ordinary letter keyboard — and every letter passed. Device log 2026-08-21 14:39:42:
    ///
    ///     Reaction on 46c9c015… from ffeeddc6… set(emoji: "H", timestampMs: 1787323181388)
    ///
    /// On the way in, this is what `incoming(actionRawValue:emoji:)` validates a peer's reaction
    /// with. So a peer could put 32 bytes of arbitrary text on any message of ours and it would
    /// render as a badge — a small amount of attacker-chosen text drawn into the transcript.
    ///
    /// One grapheme, and it must be one Unicode considers emoji. `isEmoji` alone is not that test:
    /// it is true for `0`–`9`, `#` and `*`, which carry the emoji property because of the keycap
    /// sequences they start. A bare "3" is not a reaction, so a single scalar has to *present* as
    /// emoji; a multi-scalar cluster (skin tone, ZWJ family, keycap, flag) is one if its first
    /// scalar is emoji, which is what makes 3️⃣ acceptable while 3 is not.
    static func isValidEmoji(_ emoji: String) -> Bool {
        guard emoji.utf8.count <= maxEmojiUTF8ByteCount else { return false }
        // One extended grapheme cluster: a reaction is a single glyph, and `count` is exactly that.
        guard emoji.count == 1, let character = emoji.first else { return false }
        let scalars = character.unicodeScalars
        guard let first = scalars.first, first.properties.isEmoji else { return false }
        return scalars.count > 1 || first.properties.isEmojiPresentation
    }

    /// Map proto `ReactionAction` raw value + emoji without importing the generated type
    /// into this decision. 0 unspecified with a valid emoji is treated as ADD so a
    /// forgetful producer still applies; empty unspecified is invalid.
    static func incoming(actionRawValue: Int, emoji: String) -> Incoming? {
        switch actionRawValue {
        case 1: // ADD
            guard isValidEmoji(emoji) else { return nil }
            return .add(emoji: emoji)
        case 2: // REMOVE
            return .remove
        case 0: // UNSPECIFIED
            guard isValidEmoji(emoji) else { return nil }
            return .add(emoji: emoji)
        default:
            return nil
        }
    }

    static func apply(
        existing: Row?,
        incoming: Incoming?,
        timestampMs: Int64,
        targetMessageId: String
    ) -> Decision {
        guard isValidTargetId(targetMessageId) else { return .dropInvalid }
        guard let incoming else { return .dropInvalid }
        guard timestampMs >= 0 else { return .dropInvalid }

        guard let existing else {
            switch incoming {
            case .add(let emoji):
                return .set(emoji: emoji, timestampMs: timestampMs)
            case .remove:
                return .keepExisting
            }
        }

        if timestampMs < existing.timestampMs {
            return .keepExisting
        }
        if timestampMs == existing.timestampMs {
            return .keepExisting
        }

        switch incoming {
        case .add(let emoji):
            return .set(emoji: emoji, timestampMs: timestampMs)
        case .remove:
            return .clear
        }
    }

    /// Repeat tap on the same emoji removes; any other tap sets/replaces.
    static func localToggle(currentEmoji: String?, tapped: String) -> Incoming? {
        guard isValidEmoji(tapped) else { return nil }
        if currentEmoji == tapped { return .remove }
        return .add(emoji: tapped)
    }

    /// Local tap → wire payload. `nowMs` is the LWW clock the send path stamps
    /// into `ReactionMessage.timestamp_ms` and into the optimistic row.
    static func sendPlan(
        targetMessageId: String,
        currentEmoji: String?,
        tapped: String,
        nowMs: Int64
    ) -> SendPlan? {
        guard isValidTargetId(targetMessageId), nowMs > 0 else { return nil }
        guard let incoming = localToggle(currentEmoji: currentEmoji, tapped: tapped) else { return nil }
        return SendPlan(
            targetMessageId: targetMessageId.lowercased(),
            incoming: incoming,
            timestampMs: nowMs
        )
    }

    static func shouldEvictOrphan(targetExists: Bool, receivedAtMs: Int64, nowMs: Int64) -> Bool {
        if targetExists { return false }
        return nowMs &- receivedAtMs >= Int64(orphanTTLSeconds * 1000)
    }
}
