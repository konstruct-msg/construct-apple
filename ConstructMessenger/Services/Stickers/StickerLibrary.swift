//
//  StickerLibrary.swift
//  Construct Messenger
//
//  What the picker shows: the recents and the installed packs, read from the pack store, with
//  thumbnails decoded once and held small. The picker holds thumbnails, not 512×512 decodes —
//  a full decode is ~1 MB and a grid page shows dozens.
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
@Observable
final class StickerLibrary {
    private(set) var recent: [StickerReference] = []
    private(set) var packs: [StickerPack] = []

    let store: StickerPackStore

    /// Decoded, downscaled thumbnails by sha256 hex. NSCache so memory pressure can take them.
    private let thumbnails = NSCache<NSString, PlatformImage>()

    @MainActor
    convenience init() {
        self.init(store: StickerService.shared.store)
    }

    init(store: StickerPackStore) {
        self.store = store
        thumbnails.countLimit = 256
    }

    var isEmpty: Bool { recent.isEmpty && packs.isEmpty }

    func reload() {
        recent = store.recent()
        packs = store.installedPacks().compactMap(store.pack)
    }

    /// Recents that still resolve — a pack uninstalled since is dropped from the row rather than
    /// shown as an emoji that cannot be sent.
    var sendableRecent: [StickerReference] {
        recent.filter { ref in
            packs.first { $0.id == ref.pack }?.stickers.indices.contains(Int(ref.index)) == true
        }
    }

    func thumbnail(for ref: StickerReference, side: CGFloat) async -> PlatformImage? {
        guard let pack = packs.first(where: { $0.id == ref.pack }),
              pack.stickers.indices.contains(Int(ref.index))
        else { return nil }
        let entry = pack.stickers[Int(ref.index)]
        let key = entry.sha256.map { String(format: "%02x", $0) }.joined() as NSString
        if let hit = thumbnails.object(forKey: key) { return hit }
        let store = self.store
        let image: PlatformImage? = await Task.detached(priority: .userInitiated) {
            guard let data = store.blobs.data(for: entry.sha256) else { return nil }
            #if canImport(UIKit)
            let scale = await MainActor.run { UIScreen.main.scale }
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: side * scale, height: side * scale))
            #else
            return PlatformImage(data: data)
            #endif
        }.value
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    #if DEBUG
    /// The fixture pack, for the tab's empty state before a catalog exists.
    func installFixture() {
        do {
            try StickerFixturePack.install(into: store)
            reload()
            StickerService.shared.noteInstalledLocally()
        } catch {
            Log.error("Fixture sticker pack install failed: \(error)", category: "Stickers")
        }
    }
    #endif
}
