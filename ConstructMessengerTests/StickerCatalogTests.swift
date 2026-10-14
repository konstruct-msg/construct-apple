//
//  StickerCatalogTests.swift
//  ConstructMessengerTests
//
//  The catalog is pointers the server sent; what the picker may do with them is decided here.
//

import CryptoKit
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

@MainActor
final class StickerCatalogTests: XCTestCase {

    private static let signingKey = Curve25519.Signing.PrivateKey()

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Stickers/pack")
    }

    /// Serves the fixture pack signed by this test's key, plus whatever catalog rows it is told.
    private final class Mock: StickerPackFetching, @unchecked Sendable {
        var manifest = Data()
        var rows: [Shared_Proto_Services_V1_StickerPackSummary] = []
        var failCatalog = false
        var failManifest = false
        var blobs: [Data: Data] = [:]
        var blobCalls = 0
        private let lock = NSLock()

        func manifestBytes(for pack: StickerPackID) async throws -> Data {
            if failManifest { throw URLError(.networkConnectionLost) }
            return manifest
        }
        func blobs(for pack: StickerPackID, have: [Data], onBlob: @escaping @Sendable (Data, Data) throws -> Void) async throws {
            for (sha, data) in blobs where !have.contains(sha) { try onBlob(sha, data) }
        }
        func catalog() async throws -> [Shared_Proto_Services_V1_StickerPackSummary] {
            if failCatalog { throw URLError(.notConnectedToInternet) }
            return rows
        }
        func blob(_ sha256: Data) async throws -> Data {
            lock.withLock { blobCalls += 1 }
            guard let d = blobs[sha256] else { throw URLError(.fileDoesNotExist) }
            return d
        }
    }

    private func fixture() throws -> (mock: Mock, id: StickerPackID, row: Shared_Proto_Services_V1_StickerPackSummary) {
        var m = try Shared_Proto_Messaging_V1_StickerPackManifest(serializedBytes: Data(contentsOf: fixtureDir.appendingPathComponent("manifest.pb")))
        m.signature = try Self.signingKey.signature(for: try StickerPack.canonicalBytes(of: m))
        let mock = Mock()
        mock.manifest = try m.serializedData()
        for e in m.stickers {
            let hex = e.sha256.map { String(format: "%02x", $0) }.joined()
            mock.blobs[e.sha256] = try Data(contentsOf: fixtureDir.appendingPathComponent(hex + ".webp"))
        }
        var row = Shared_Proto_Services_V1_StickerPackSummary()
        row.packID = m.packID
        row.title = m.title
        row.publisher = m.publisher
        row.stickerCount = UInt32(m.stickers.count)
        row.coverSha256 = m.stickers[0].sha256
        row.totalBytes = UInt64(m.stickers.map { Int($0.byteLen) }.reduce(0, +))
        mock.rows = [row]
        return (mock, StickerPackID(m.packID)!, row)
    }

    private func makeCatalog(_ mock: Mock) -> (StickerCatalog, StickerService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-catalog-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let service = StickerService(store: StickerPackStore(root: root), fetcher: mock, trustedKeys: { [Self.signingKey.publicKey] })
        return (StickerCatalog(service: service), service)
    }

    func testRefreshListsPacksAndInstallRemovesThemFromAvailable() async throws {
        let (mock, id, _) = try fixture()
        let (catalog, service) = makeCatalog(mock)
        XCTAssertEqual(catalog.state, .idle)

        await catalog.refresh()
        XCTAssertEqual(catalog.state, .loaded)
        XCTAssertEqual(catalog.packs.map(\.id), [id])
        XCTAssertEqual(catalog.available(excluding: []).map(\.id), [id])
        XCTAssertEqual(catalog.packs[0].stickerCount, 4)
        XCTAssertEqual(catalog.packs[0].totalBytes, 9964 + 1286 + 8154 + 16578)

        let ok = await catalog.install(id)
        XCTAssertTrue(ok)
        XCTAssertEqual(service.store.installedPacks(), [id])
        XCTAssertTrue(catalog.available(excluding: service.store.installedPacks()).isEmpty, "an installed pack leaves the catalog rows")
        XCTAssertFalse(catalog.failed.contains(id))
    }

    func testMalformedRowsAreDroppedNotShown() async throws {
        let (mock, id, good) = try fixture()
        var shortId = good
        shortId.packID = Data(repeating: 1, count: 31)
        var badCover = good
        badCover.packID = Data(repeating: 2, count: 32)
        badCover.coverSha256 = Data()
        var tooMany = good
        tooMany.packID = Data(repeating: 3, count: 32)
        tooMany.stickerCount = 121
        var empty = good
        empty.packID = Data(repeating: 4, count: 32)
        empty.stickerCount = 0
        mock.rows = [shortId, badCover, good, tooMany, empty]
        let (catalog, _) = makeCatalog(mock)

        await catalog.refresh()
        XCTAssertEqual(catalog.packs.map(\.id), [id])
    }

    func testFailedFetchIsAStateAndRefreshRecovers() async throws {
        let (mock, id, _) = try fixture()
        mock.failCatalog = true
        let (catalog, _) = makeCatalog(mock)

        await catalog.refresh()
        XCTAssertEqual(catalog.state, .failed)
        XCTAssertTrue(catalog.packs.isEmpty)

        mock.failCatalog = false
        await catalog.refresh()
        XCTAssertEqual(catalog.state, .loaded)
        XCTAssertEqual(catalog.packs.map(\.id), [id])
    }

    func testFailedInstallIsRememberedUntilTheNextAttempt() async throws {
        let (mock, id, _) = try fixture()
        mock.failManifest = true
        let (catalog, service) = makeCatalog(mock)
        await catalog.refresh()

        let first = await catalog.install(id)
        XCTAssertFalse(first)
        XCTAssertTrue(catalog.failed.contains(id))
        XCTAssertFalse(service.store.isPresent(id))

        // The service backs off after a failure; move past it by using a fresh service clock
        // is not available here, so assert the catalog's own bookkeeping instead: the flag
        // clears on the next attempt even when that attempt is refused by the backoff.
        mock.failManifest = false
        let second = await catalog.install(id)
        XCTAssertFalse(second, "still inside the service's backoff window")
        XCTAssertTrue(catalog.failed.contains(id))
    }

    func testCoverComesFromTheStoreWhenHeldAndIsHashCheckedWhenFetched() async throws {
        let (mock, _, row) = try fixture()
        let (catalog, service) = makeCatalog(mock)
        await catalog.refresh()
        let summary = try XCTUnwrap(catalog.packs.first)

        // Not held: fetched by hash, once, then cached.
        let fetched = await catalog.cover(for: summary, side: 56)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(mock.blobCalls, 1)
        _ = await catalog.cover(for: summary, side: 56)
        XCTAssertEqual(mock.blobCalls, 1, "second ask is served from the cache")

        // Lying server: bytes that do not hash to the cover are refused.
        var lying = row
        lying.packID = Data(repeating: 9, count: 32)
        lying.coverSha256 = Data(repeating: 7, count: 32)
        mock.blobs[lying.coverSha256] = mock.blobs[row.coverSha256]
        let liar = try XCTUnwrap(StickerCatalog.Summary(lying))
        let refused = await catalog.cover(for: liar, side: 56)
        XCTAssertNil(refused)

        // Held: after install the cover is read from the store, no RPC. (The lying entry
        // would poison the pack stream — the mock serves everything it holds — so drop it.)
        mock.blobs[lying.coverSha256] = nil
        let calls = mock.blobCalls
        _ = await service.ensurePresent(summary.id)
        let fresh = StickerCatalog(service: service)
        await fresh.refresh()
        XCTAssertTrue(service.store.isPresent(summary.id))
        let local = await fresh.cover(for: try XCTUnwrap(fresh.packs.first), side: 56)
        XCTAssertNotNil(local)
        XCTAssertEqual(mock.blobCalls, calls, "a held blob is not fetched")
    }
}
