//
//  StickerCatalog.swift
//  Construct Messenger
//
//  What can be installed: the server's list of published packs, as the picker shows it under
//  the installed ones. A summary is a pointer, not a pack — title, count, size and a cover hash
//  are trusted for what they are: enough to decide, never enough to trust. Installing goes
//  through `StickerService`, which fetches the manifest and verifies it like any other.
//
//  Covers come by hash through the one-blob RPC. That is a catalog browse, not a receive, and
//  it is the access pattern that RPC exists for; a blob the device already holds is read from
//  the store instead, so an installed pack's cover costs nothing.
//

import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
@Observable
final class StickerCatalog {
    struct Summary: Equatable, Identifiable, Sendable {
        let id: StickerPackID
        let title: String
        let publisher: String
        let stickerCount: Int
        let coverSHA256: Data
        let totalBytes: Int

        /// A row the server sent that a client could not act on is dropped, not shown: a
        /// pack_id that is not a hash cannot be installed, a cover that is not a hash cannot
        /// be fetched, and a count outside the rules is not a pack this client will accept.
        init?(_ wire: Shared_Proto_Services_V1_StickerPackSummary) {
            guard let id = StickerPackID(wire.packID),
                  wire.coverSha256.count == StickerPackID.byteCount,
                  (1...StickerCatalog.maxStickersPerPack).contains(Int(wire.stickerCount))
            else { return nil }
            self.id = id
            title = wire.title
            publisher = wire.publisher
            stickerCount = Int(wire.stickerCount)
            coverSHA256 = wire.coverSha256
            totalBytes = Int(clamping: wire.totalBytes)
        }
    }

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// The pack ceiling the publisher enforces; a summary claiming more is not a pack.
    nonisolated static let maxStickersPerPack = 120

    private(set) var state: State = .idle
    private(set) var packs: [Summary] = []
    /// Installs in flight, so a row can show progress and refuse a second tap.
    private(set) var installing: Set<StickerPackID> = []
    /// Installs that failed, so a row can say so until the next attempt.
    private(set) var failed: Set<StickerPackID> = []

    private let service: StickerService
    private let covers = NSCache<NSString, PlatformImage>()

    init(service: StickerService) {
        self.service = service
        covers.countLimit = 64
    }

    @MainActor
    convenience init() {
        self.init(service: StickerService.shared)
    }

    /// The catalog minus what the device already lists — a pack that is present but not
    /// installed (fetched for a peer's sticker) is offered, since installing it is one write.
    func available(excluding installed: [StickerPackID]) -> [Summary] {
        let hidden = Set(installed)
        return packs.filter { !hidden.contains($0.id) }
    }

    func refresh() async {
        if state == .loading { return }
        state = .loading
        do {
            packs = try await service.catalog().compactMap(Summary.init)
            state = .loaded
        } catch {
            Log.error("Sticker catalog fetch failed: \(error)", category: "Stickers")
            state = .failed
        }
    }

    /// Install through the service — fetch whole, verify, mark installed. Returns whether the
    /// pack is installed on return.
    @discardableResult
    func install(_ id: StickerPackID) async -> Bool {
        if installing.contains(id) { return false }
        installing.insert(id)
        failed.remove(id)
        defer { installing.remove(id) }
        do {
            try await service.install(id)
            return true
        } catch {
            failed.insert(id)
            return false
        }
    }

    func cover(for summary: Summary, side: CGFloat) async -> PlatformImage? {
        let key = summary.coverSHA256.map { String(format: "%02x", $0) }.joined() as NSString
        if let hit = covers.object(forKey: key) { return hit }
        guard let data = try? await service.blob(summary.coverSHA256) else { return nil }
        let image: PlatformImage? = await Task.detached(priority: .userInitiated) {
            #if canImport(UIKit)
            let scale = await MainActor.run { UIScreen.main.scale }
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: side * scale, height: side * scale))
            #else
            return PlatformImage(data: data)
            #endif
        }.value
        if let image { covers.setObject(image, forKey: key) }
        return image
    }
}
