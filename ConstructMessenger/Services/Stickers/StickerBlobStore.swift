//
//  StickerBlobStore.swift
//  Construct Messenger
//
//  Sticker bytes on disk, keyed by their SHA-256. Content-addressed and immutable: an entry is
//  correct forever or it is a different hash, so there is no TTL, no version and no
//  invalidation — only the checks on the way in.
//
//  Not the media cache. `MediaSendCache` expires at six days beneath the server's seven-day
//  media TTL, which is right for a photo and fatal for a pack that must resolve for as long as
//  any message referencing it exists. Sticker bytes never go through `MediaManager`.
//
//  Eviction (LRU over packs the user has not installed, 200 MB cap) needs the manifest to know
//  what is pinned, and the manifest arrives with the sticker service. Until then this store only
//  grows, and a fixture pack is a few hundred kilobytes.
//

import CryptoKit
import Foundation

struct StickerBlobStore {
    enum PutError: Error, Equatable {
        case tooLarge(Int)
        case hashMismatch
        case notAStickerImage
    }

    let root: URL

    /// `Library/Caches/stickers/blobs`. Caches so that the system may reclaim it under
    /// pressure; a lost blob is re-fetched with its pack, never lost history.
    static func `default`() -> StickerBlobStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return StickerBlobStore(root: caches.appendingPathComponent("stickers/blobs", isDirectory: true))
    }

    func url(for sha256: Data) -> URL {
        root.appendingPathComponent(sha256.map { String(format: "%02x", $0) }.joined() + ".webp")
    }

    func contains(_ sha256: Data) -> Bool {
        FileManager.default.fileExists(atPath: url(for: sha256).path)
    }

    func data(for sha256: Data) -> Data? {
        try? Data(contentsOf: url(for: sha256))
    }

    /// Verify, then write. The order is the point: nothing is written until the bytes are the
    /// bytes the signed manifest named, of a size the rules allow, with a header that says
    /// static 512×512 — a server that lies gets nothing into the cache.
    ///
    /// Written to a sibling temporary and moved, so a crash mid-write leaves no file at the
    /// hash's path that `contains` would then trust.
    func put(_ data: Data, expecting sha256: Data) throws {
        guard data.count <= StickerImageRules.maxBytes else { throw PutError.tooLarge(data.count) }
        guard Data(SHA256.hash(data: data)) == sha256 else { throw PutError.hashMismatch }
        guard let header = try? WebPHeader.parse(data), header.isStickerCanvas else {
            throw PutError.notAStickerImage
        }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let final = url(for: sha256)
        if fm.fileExists(atPath: final.path) { return }   // same hash, same bytes
        let tmp = root.appendingPathComponent(".\(UUID().uuidString).part")
        try data.write(to: tmp, options: .atomic)
        do {
            try fm.moveItem(at: tmp, to: final)
        } catch {
            try? fm.removeItem(at: tmp)
            // A concurrent put of the same hash won the move; the content is identical.
            if fm.fileExists(atPath: final.path) { return }
            throw error
        }
    }

    func remove(_ sha256: Data) {
        try? FileManager.default.removeItem(at: url(for: sha256))
    }
}
