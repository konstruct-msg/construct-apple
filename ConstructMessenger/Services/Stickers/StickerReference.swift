//
//  StickerReference.swift
//  Construct Messenger
//
//  A sticker on the wire is a pack hash, an index and an emoji — ~40 bytes inside the E2EE
//  plaintext, never pixels. This is the validated form of `Shared_Proto_Messaging_V1_StickerRef`
//  and the only shape the rest of the app handles: a reference that failed validation never
//  becomes a `StickerReference`, so nothing downstream has to ask whether it did.
//
//  The rules are cross-client — `construct-protos/conformance/knst_sticker_ref.json`, vendored
//  into Generated/conformance/ — and `StickerRefConformanceTests` holds the constants below to
//  that file. Decisions: sticker-id-wire-not-media (carrier), sticker-packs-content-addressed
//  (shape).
//

import Foundation

/// The identity of a pack: the SHA-256 of its canonical signed manifest, and nothing else.
///
/// Exactly 32 bytes by construction. There is no version and no name in the identity — a pack
/// that changes is a different pack — which is what lets the cache keep an entry forever.
struct StickerPackID: Hashable, Sendable {
    static let byteCount = 32

    let bytes: Data

    init?(_ data: Data) {
        guard data.count == Self.byteCount else { return nil }
        // Re-based so that equality and hashing see the bytes, not a slice's start index.
        bytes = Data(data)
    }

    /// Lowercase hex — the cache path and the log form. Never the wire form.
    var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// The wire's validation rules, as the vector file states them.
///
/// `emoji` is measured in UTF-8 bytes, not graphemes or scalars: grapheme segmentation depends
/// on the ICU version and would differ between iOS, Rust and Android, byte length does not.
/// 32 bytes admits every single emoji grapheme in use — a ZWJ family is 25, a tag-sequence flag
/// is 28. `index` is not validated here: its bound is the manifest's sticker count, which is
/// known only once the pack is present.
enum StickerWireRules {
    static let packIdBytes = StickerPackID.byteCount
    static let emojiMinBytes = 1
    static let emojiMaxBytes = 32

    static func emojiIsValid(_ emoji: String) -> Bool {
        (emojiMinBytes...emojiMaxBytes).contains(emoji.utf8.count)
    }
}

/// A validated sticker reference — what a bubble renders and what a send serializes.
struct StickerReference: Hashable, Sendable {
    let pack: StickerPackID
    /// Position in the pack manifest's sticker list. Stable, because the pack is immutable.
    let index: UInt32
    /// Duplicated from the manifest on purpose: the one thing that renders with nothing
    /// downloaded, and the text preview in the chat list.
    let emoji: String

    init?(pack: StickerPackID, index: UInt32, emoji: String) {
        guard StickerWireRules.emojiIsValid(emoji) else { return nil }
        self.pack = pack
        self.index = index
        self.emoji = emoji
    }

    /// `nil` is "corrupt message content": not rendered as a sticker, not stored as one, and
    /// the fields never reach a filesystem path.
    init?(wire: Shared_Proto_Messaging_V1_StickerRef) {
        guard let pack = StickerPackID(wire.packID) else { return nil }
        self.init(pack: pack, index: wire.index, emoji: wire.emoji)
    }

    var wire: Shared_Proto_Messaging_V1_StickerRef {
        var ref = Shared_Proto_Messaging_V1_StickerRef()
        ref.packID = pack.bytes
        ref.index = index
        ref.emoji = emoji
        return ref
    }
}
