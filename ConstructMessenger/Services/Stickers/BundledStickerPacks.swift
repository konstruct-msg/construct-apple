//
//  BundledStickerPacks.swift
//  Construct Messenger
//
//  Packs that ship inside the app. The first pack has nowhere else to come from: a device
//  installs a pack from the catalog or from a peer's StickerRef, and on day one there is no
//  catalog UI and no peer who has it. So the pack rides in the bundle and is seeded into the
//  store on first launch, once — an uninstall is respected on every launch after.
//
//  A bundled pack is the same pack the server publishes, byte for byte where it matters: the
//  manifest's `pack_id` is the hash of its canonical bytes, so a device that got it from the
//  bundle and a device that fetched it hold the same id, and a StickerRef between them
//  resolves. Trust is established the same way as for a fetched pack — the signature against
//  the pinned bundle-signing keys — with one exemption: a DEBUG build accepts an unsigned
//  manifest from its own bundle (the rule the proto states). A release build does not; an
//  unsigned bundled pack in release is simply absent, never trusted because it was near.
//
//  Layout in the bundle (the synchronized group flattens `ConstructMessenger/StickerPacks/` to
//  the bundle root, the same way it does the fonts):
//
//      sticker-pack-<name>.pb      StickerPackManifest, pack_id set, signature set when signed
//      <sha256 hex>.webp           every blob the manifest names
//

import Foundation

/// Where bundled packs are read from. `Bundle` in the app; a dictionary in tests, because a
/// `Bundle` cannot be assembled from a temporary directory on every platform.
protocol BundledPackSource {
    /// Every bundled manifest's bytes, in no particular order.
    func manifests() -> [Data]
    /// The blob for one hash, or nil if the bundle does not carry it.
    func blob(_ sha256: Data) -> Data?
}

enum BundledStickerPacks {
    static let manifestPrefix = "sticker-pack-"
    static let manifestExtension = "pb"
    static let blobExtension = "webp"

    /// The pack ids seeded so far, so a pack the person removed is not put back on the next
    /// launch. Keyed by pack id, not by file name: a re-signed manifest is the same pack.
    static let seededDefaultsKey = "stickers.bundled.seeded"

    /// Bundled packs a newer pack replaced, by pack id hex. A pack has no versions — its id is the
    /// hash of its manifest — so a redrawn pack is a different pack, and messages already sent
    /// keep naming the old one. A retired pack therefore stays in the bundle and is made present,
    /// so those messages render as images on any device, fetch or no fetch; it is only taken off
    /// the picker, once, which is what `retiredDefaultsKey` remembers — a person who installs it
    /// again from the catalog keeps it.
    static let retired: Set<String> = [
        // Momo the cat, nine stickers — replaced 2026-09-24 by the fourteen-sticker redraw.
        "96faa6e6d33167276d172920cd00d8bc8017fc39ab66e366516b338fcfc882f1",
    ]
    static let retiredDefaultsKey = "stickers.bundled.retired"

    /// Accepted unsigned only where the proto says a client may: DEBUG, own bundle.
    static var allowUnsigned: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

extension Bundle: BundledPackSource {
    func manifests() -> [Data] {
        (urls(forResourcesWithExtension: BundledStickerPacks.manifestExtension, subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(BundledStickerPacks.manifestPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? Data(contentsOf: $0) }
    }

    func blob(_ sha256: Data) -> Data? {
        let hex = sha256.map { String(format: "%02x", $0) }.joined()
        guard let url = url(forResource: hex, withExtension: BundledStickerPacks.blobExtension) else { return nil }
        return try? Data(contentsOf: url)
    }
}
