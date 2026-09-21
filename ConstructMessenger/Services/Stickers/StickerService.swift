//
//  StickerService.swift
//  Construct Messenger
//
//  Makes packs present. A bubble that finds no blob asks for the pack; the picker's install
//  asks for the pack; both land here, once per pack at a time, with a backoff after failure so
//  a withdrawn or unreachable pack is not hammered by every row that references it.
//
//  Whole packs, never single stickers: the one request per pack per device is the privacy
//  property (decisions/sticker-packs-content-addressed.md). Trust is established here and
//  nowhere else — the manifest's signature against the pinned bundle-signing keys, its hash
//  against its pack_id — and the blobs are verified on the way into the store.
//
//  `installedGeneration` is the signal the transcript waits on: it advances when a pack becomes
//  present, and a sticker bubble keyed on it reloads. Without it a bubble that rendered the
//  emoji while the pack was in flight would keep the emoji until it was scrolled away.
//

import CryptoKit
import Foundation

@MainActor
@Observable
final class StickerService {
    static let shared = StickerService()

    /// The catalog is small and published; a ceiling only guards against a runaway pager.
    static let catalogCeiling = 500

    /// Advances every time a pack becomes present. Observe it to re-resolve a reference.
    private(set) var installedGeneration = 0

    let store: StickerPackStore
    private let fetcher: any StickerPackFetching
    private let trustedKeys: () -> [Curve25519.Signing.PublicKey]
    private let now: () -> Date

    /// One fetch per pack at a time; a second caller awaits the first.
    private var inFlight: [StickerPackID: Task<Bool, Never>] = [:]
    /// Packs that failed, and when they may be tried again.
    private var backoff: [StickerPackID: (until: Date, failures: Int)] = [:]

    static let firstRetry: TimeInterval = 30
    static let maxRetry: TimeInterval = 15 * 60

    init(
        store: StickerPackStore = .default(),
        fetcher: any StickerPackFetching = StickerPackFetcher(),
        trustedKeys: @escaping () -> [Curve25519.Signing.PublicKey] = { BundleSigningTrust.trustedKeys() },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.fetcher = fetcher
        self.trustedKeys = trustedKeys
        self.now = now
    }

    // MARK: - Presence

    /// Make the pack present if it is not, honouring the backoff. Returns whether it is present
    /// on return. Safe to call from every bubble that needs it: coalesced per pack.
    @discardableResult
    func ensurePresent(_ pack: StickerPackID) async -> Bool {
        if store.isPresent(pack) { return true }
        if let task = inFlight[pack] { return await task.value }
        if let entry = backoff[pack], now() < entry.until { return false }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.fetchAndInstall(pack)
        }
        inFlight[pack] = task
        let ok = await task.value
        inFlight[pack] = nil
        return ok
    }

    private func fetchAndInstall(_ pack: StickerPackID) async -> Bool {
        do {
            let manifestBytes = try await fetcher.manifestBytes(for: pack)
            let verified = try StickerPack.verify(manifestBytes: manifestBytes, trustedKeys: trustedKeys())
            guard verified.id == pack else { throw StickerPack.VerifyError.packIdMismatch }

            // Everything the manifest names that is not already on disk, in one stream, each
            // blob through the store's checks as it lands. `install` then writes the manifest
            // last — a stream that ends early leaves the pack absent, not half-present.
            let have = verified.stickers.map(\.sha256).filter(store.blobs.contains)
            let blobs = store.blobs
            try await fetcher.blobs(for: pack, have: have) { sha256, data in
                try blobs.put(data, expecting: sha256)
            }
            try store.install(verified, manifestBytes: manifestBytes) { _ in nil }

            backoff[pack] = nil
            installedGeneration += 1
            Log.info("Sticker pack \(pack.hex.prefix(16))… present: \(verified.stickers.count) stickers", category: "Stickers")
            return true
        } catch {
            let failures = (backoff[pack]?.failures ?? 0) + 1
            let delay = min(Self.firstRetry * pow(2, Double(failures - 1)), Self.maxRetry)
            backoff[pack] = (now().addingTimeInterval(delay), failures)
            Log.error("Sticker pack \(pack.hex.prefix(16))… fetch failed (\(failures)): \(error) — next try in \(Int(delay))s", category: "Stickers")
            return false
        }
    }

    // MARK: - Library

    /// Install from the catalog: present, then marked installed so the picker lists it.
    func install(_ pack: StickerPackID) async throws {
        guard await ensurePresent(pack) else { throw InstallError.unavailable }
        try store.setInstalled(pack, true)
        installedGeneration += 1
    }

    func uninstall(_ pack: StickerPackID) throws {
        try store.setInstalled(pack, false)
        installedGeneration += 1
    }

    #if DEBUG
    /// A pack put on disk by something other than a fetch (the fixture). Bubbles reload.
    func noteInstalledLocally() { installedGeneration += 1 }
    #endif

    func catalog() async throws -> [Shared_Proto_Services_V1_StickerPackSummary] {
        try await fetcher.catalog()
    }

    enum InstallError: Error, Equatable {
        case unavailable
    }
}
