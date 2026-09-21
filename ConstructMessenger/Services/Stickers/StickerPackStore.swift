//
//  StickerPackStore.swift
//  Construct Messenger
//
//  Packs on disk: verified manifests beside the content-addressed blobs, plus the two small
//  facts that are not content — which packs the user installed, and which stickers they used
//  last. A pack is "present" only when its manifest is on disk, and the manifest is written last,
//  so a pack whose blobs did not all arrive is not present rather than half-present.
//
//  Layout, under Library/Caches/stickers/:
//      manifests/{pack_id hex}.pb
//      blobs/{sha256 hex}.webp          (StickerBlobStore)
//      installed.json                    [pack_id hex]
//      recent.json                       [{pack, index, emoji}], newest first, ≤ 24
//

import Foundation

struct StickerPackStore {
    enum InstallError: Error, Equatable {
        case blobMissing(index: Int)
        case blobRejected(index: Int)
    }

    static let recentLimit = 24

    let root: URL
    let blobs: StickerBlobStore

    init(root: URL) {
        self.root = root
        self.blobs = StickerBlobStore(root: root.appendingPathComponent("blobs", isDirectory: true))
    }

    static func `default`() -> StickerPackStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return StickerPackStore(root: caches.appendingPathComponent("stickers", isDirectory: true))
    }

    private var manifests: URL { root.appendingPathComponent("manifests", isDirectory: true) }
    private func manifestURL(_ id: StickerPackID) -> URL { manifests.appendingPathComponent(id.hex + ".pb") }
    private var installedURL: URL { root.appendingPathComponent("installed.json") }
    private var recentURL: URL { root.appendingPathComponent("recent.json") }

    // MARK: - Presence

    /// The verified pack, or nil. Re-verified on read: the file is ours, but "present means
    /// verified" is cheaper to keep true than to reason about.
    func pack(_ id: StickerPackID) -> StickerPack? {
        guard let bytes = try? Data(contentsOf: manifestURL(id)),
              let pack = try? StickerPack.verify(manifestBytes: bytes, allowUnsigned: true),
              pack.id == id
        else { return nil }
        return pack
    }

    func isPresent(_ id: StickerPackID) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(id).path)
    }

    /// The bytes for one sticker of a present pack, or nil — the caller renders the emoji.
    func blob(for ref: StickerReference) -> Data? {
        guard let pack = pack(ref.pack),
              pack.stickers.indices.contains(Int(ref.index))
        else { return nil }
        return blobs.data(for: pack.stickers[Int(ref.index)].sha256)
    }

    // MARK: - Install

    /// Make a verified pack present: every blob through the blob store's checks, then the
    /// manifest. `blobBytes` is asked per entry so the fetcher can stream; a nil answer or a
    /// refused blob aborts, and nothing written so far makes the pack present.
    func install(
        _ pack: StickerPack,
        manifestBytes: Data,
        blobBytes: (StickerPack.Entry) throws -> Data?
    ) throws {
        for (i, entry) in pack.stickers.enumerated() {
            if blobs.contains(entry.sha256) { continue }
            guard let data = try blobBytes(entry) else { throw InstallError.blobMissing(index: i) }
            do {
                try blobs.put(data, expecting: entry.sha256)
            } catch {
                throw InstallError.blobRejected(index: i)
            }
        }
        try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
        try manifestBytes.write(to: manifestURL(pack.id), options: .atomic)
    }

    // MARK: - Installed set and recents

    func installedPacks() -> [StickerPackID] {
        guard let data = try? Data(contentsOf: installedURL),
              let hexes = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return hexes.compactMap { StickerPackID(Data(hex: $0)) }.filter(isPresent)
    }

    func setInstalled(_ id: StickerPackID, _ installed: Bool) throws {
        var ids = installedPacks()
        ids.removeAll { $0 == id }
        if installed { ids.append(id) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids.map(\.hex)).write(to: installedURL, options: .atomic)
    }

    private struct RecentRow: Codable {
        var pack: String
        var index: UInt32
        var emoji: String
    }

    func recent() -> [StickerReference] {
        guard let data = try? Data(contentsOf: recentURL),
              let rows = try? JSONDecoder().decode([RecentRow].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            guard let id = StickerPackID(Data(hex: row.pack)) else { return nil }
            return StickerReference(pack: id, index: row.index, emoji: row.emoji)
        }
    }

    func recordUsed(_ ref: StickerReference) throws {
        var list = recent().filter { $0 != ref }
        list.insert(ref, at: 0)
        list = Array(list.prefix(Self.recentLimit))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rows = list.map { RecentRow(pack: $0.pack.hex, index: $0.index, emoji: $0.emoji) }
        try JSONEncoder().encode(rows).write(to: recentURL, options: .atomic)
    }
}

private extension Data {
    init(hex: String) {
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let b = UInt8(hex[i..<j], radix: 16) else { self = Data(); return }
            out.append(b)
            i = j
        }
        self = out
    }
}
