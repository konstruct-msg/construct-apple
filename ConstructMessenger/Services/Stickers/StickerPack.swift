//
//  StickerPack.swift
//  Construct Messenger
//
//  A pack the client has verified: the manifest's own hash is its `pack_id`, every entry is a
//  well-formed sticker description, and — once the service ships its key — the signature is the
//  publisher's. Only a `StickerPack` gets a manifest written to disk, so "present" means
//  "verified" everywhere else.
//
//  The canonical bytes are what `construct-protos/conformance/knst_sticker_pack.json` fixes:
//  proto3 binary, ascending field order, pack_id and signature cleared. `StickerPackTests` holds
//  this implementation to that file.
//

import CryptoKit
import Foundation
import SwiftProtobuf   // serializedData — explicit under #MemberImportVisibility

struct StickerPack: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let sha256: Data
        let emoji: String
        let byteLen: Int
    }

    let id: StickerPackID
    let title: String
    let publisher: String
    let stickers: [Entry]

    enum VerifyError: Error, Equatable {
        case undecodable
        case packIdMismatch
        case badEntry(index: Int)
        case unsigned
    }

    /// The bytes a pack's identity is computed over: the manifest with `pack_id` and
    /// `signature` cleared, serialized. Deterministic for this message — scalars and a repeated
    /// message, no maps — which is what lets a publisher and every client agree on it.
    static func canonicalBytes(of manifest: Shared_Proto_Messaging_V1_StickerPackManifest) throws -> Data {
        var m = manifest
        m.packID = Data()
        m.signature = Data()
        return try m.serializedData()
    }

    static func packId(of manifest: Shared_Proto_Messaging_V1_StickerPackManifest) throws -> Data {
        Data(SHA256.hash(data: try canonicalBytes(of: manifest)))
    }

    /// Verify a fetched or bundled manifest. Order: decode → hash → entries → signature, so the
    /// cheapest refusal comes first and an unsigned manifest is refused only once everything
    /// else about it is known to be right (which is what makes the DEBUG exemption safe).
    ///
    /// `allowUnsigned` is for fixture packs in a DEBUG bundle and nothing else; the pinned
    /// publisher key arrives with the sticker service, and until then no signed pack exists.
    static func verify(manifestBytes: Data, allowUnsigned: Bool = false) throws -> StickerPack {
        guard let manifest = try? Shared_Proto_Messaging_V1_StickerPackManifest(serializedBytes: manifestBytes) else {
            throw VerifyError.undecodable
        }
        guard let id = StickerPackID(manifest.packID),
              try packId(of: manifest) == id.bytes else {
            throw VerifyError.packIdMismatch
        }
        var entries: [Entry] = []
        for (i, e) in manifest.stickers.enumerated() {
            guard e.sha256.count == StickerPackID.byteCount,
                  StickerWireRules.emojiIsValid(e.emoji),
                  Int(e.width) == StickerImageRules.canvas, Int(e.height) == StickerImageRules.canvas,
                  e.byteLen > 0, Int(e.byteLen) <= StickerImageRules.maxBytes
            else { throw VerifyError.badEntry(index: i) }
            entries.append(Entry(sha256: Data(e.sha256), emoji: e.emoji, byteLen: Int(e.byteLen)))
        }
        if manifest.signature.isEmpty {
            guard allowUnsigned else { throw VerifyError.unsigned }
        }
        // A non-empty signature is not checked yet: there is no pinned key to check it against.
        // When the service ships one, this is where the check goes, and `unsigned` stays.
        return StickerPack(id: id, title: manifest.title, publisher: manifest.publisher, stickers: entries)
    }

    /// The reference a send builds: the pack's identity, the position, the entry's emoji.
    func reference(at index: Int) -> StickerReference? {
        guard stickers.indices.contains(index) else { return nil }
        return StickerReference(pack: id, index: UInt32(index), emoji: stickers[index].emoji)
    }
}
