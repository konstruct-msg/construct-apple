//
//  StickerServiceTests.swift
//  ConstructMessengerTests
//
//  The service against a fetcher that answers from the fixture pack: a signed manifest becomes
//  a present pack and the generation advances; every way the server can lie leaves the pack
//  absent; concurrent askers share one fetch; a failure backs off.
//

import CryptoKit
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

@MainActor
final class StickerServiceTests: XCTestCase {

    // MARK: - Fixture + a signing key of our own

    private static let signingKey = Curve25519.Signing.PrivateKey()

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Stickers/pack")
    }

    /// The fixture manifest, signed by this test's key. Same pack_id: the signature is outside
    /// the canonical bytes.
    private func signedManifest() throws -> (bytes: Data, id: StickerPackID) {
        var m = try Shared_Proto_Messaging_V1_StickerPackManifest(serializedBytes: Data(contentsOf: fixtureDir.appendingPathComponent("manifest.pb")))
        m.signature = try Self.signingKey.signature(for: try StickerPack.canonicalBytes(of: m))
        return (try m.serializedData(), StickerPackID(m.packID)!)
    }

    private func blob(_ sha: Data) throws -> Data {
        try Data(contentsOf: fixtureDir.appendingPathComponent(sha.map { String(format: "%02x", $0) }.joined() + ".webp"))
    }

    /// Answers from the fixture, with knobs for lying. Counts calls.
    private final class Mock: StickerPackFetching, @unchecked Sendable {
        var manifest: Data
        var swapFirstBlob = false
        var failBlobs = false
        var manifestCalls = 0
        var blobCalls = 0
        var blobsServed = 0
        let blobReader: (Data) throws -> Data
        let entries: [Data]
        private let lock = NSLock()

        init(manifest: Data, entries: [Data], blobReader: @escaping (Data) throws -> Data) {
            self.manifest = manifest; self.entries = entries; self.blobReader = blobReader
        }

        func manifestBytes(for pack: StickerPackID) async throws -> Data {
            lock.withLock { manifestCalls += 1 }
            try await Task.sleep(for: .milliseconds(20))   // long enough for a second asker to queue
            return manifest
        }

        func blobs(for pack: StickerPackID, have: [Data], onBlob: @escaping @Sendable (Data, Data) throws -> Void) async throws {
            lock.withLock { blobCalls += 1 }
            if failBlobs { throw URLError(.networkConnectionLost) }
            for (i, sha) in entries.enumerated() where !have.contains(sha) {
                var data = try blobReader(sha)
                if swapFirstBlob, i == 0 { data = try blobReader(entries[1]) }
                try onBlob(sha, data)
                lock.withLock { blobsServed += 1 }
            }
        }

        func catalog() async throws -> [Shared_Proto_Services_V1_StickerPackSummary] { [] }
        func blob(_ sha256: Data) async throws -> Data { try blobReader(sha256) }
    }

    private var clock = Date()

    private func makeService(_ mock: Mock, keys: [Curve25519.Signing.PublicKey]? = nil) -> StickerService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-service-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return StickerService(
            store: StickerPackStore(root: root),
            fetcher: mock,
            trustedKeys: { keys ?? [Self.signingKey.publicKey] },
            now: { self.clock }
        )
    }

    private func mock() throws -> (Mock, StickerPackID) {
        let (bytes, id) = try signedManifest()
        let entries = try StickerPack.verify(manifestBytes: bytes, trustedKeys: [Self.signingKey.publicKey]).stickers.map(\.sha256)
        return (Mock(manifest: bytes, entries: entries, blobReader: blob), id)
    }

    // MARK: - Happy path

    func testSignedPackBecomesPresentAndGenerationAdvances() async throws {
        let (mock, id) = try mock()
        let service = makeService(mock)
        let before = service.installedGeneration

        let ok = await service.ensurePresent(id)
        XCTAssertTrue(ok)
        XCTAssertTrue(service.store.isPresent(id))
        XCTAssertEqual(service.installedGeneration, before + 1)
        XCTAssertEqual(mock.blobsServed, 4)
        XCTAssertEqual(service.store.pack(id)?.stickers.count, 4)

        // Present: no second fetch.
        let present1 = await service.ensurePresent(id)
        XCTAssertTrue(present1)
        XCTAssertEqual(mock.manifestCalls, 1)
    }

    /// The store already holds two of the blobs (a shared sticker, an earlier partial fetch):
    /// the fetcher is told so and serves only the rest.
    func testAlreadyHeldBlobsAreNotRefetched() async throws {
        let (mock, id) = try mock()
        let service = makeService(mock)
        for sha in mock.entries.prefix(2) { try service.store.blobs.put(try blob(sha), expecting: sha) }

        let present1 = await service.ensurePresent(id)
        XCTAssertTrue(present1)
        XCTAssertEqual(mock.blobsServed, 2)
    }

    // MARK: - Every way the server can lie

    func testUnsignedManifestIsRefused() async throws {
        let (mock, id) = try mock()
        mock.manifest = try Data(contentsOf: fixtureDir.appendingPathComponent("manifest.pb"))   // signature empty
        let service = makeService(mock)
        let present1 = await service.ensurePresent(id)
        XCTAssertFalse(present1)
        XCTAssertFalse(service.store.isPresent(id))
        XCTAssertEqual(mock.blobCalls, 0, "no blob is fetched for a manifest that did not verify")
    }

    func testSignatureFromAnUntrustedKeyIsRefused() async throws {
        let (mock, id) = try mock()
        let service = makeService(mock, keys: [Curve25519.Signing.PrivateKey().publicKey])
        let present1 = await service.ensurePresent(id)
        XCTAssertFalse(present1)
        XCTAssertFalse(service.store.isPresent(id))
        XCTAssertEqual(mock.blobCalls, 0)
    }

    /// The server answers a request for pack X with a perfectly valid pack Y.
    func testManifestForADifferentPackIsRefused() async throws {
        let (mock, _) = try mock()
        let service = makeService(mock)
        let other = StickerPackID(Data(repeating: 0x77, count: 32))!
        let present1 = await service.ensurePresent(other)
        XCTAssertFalse(present1)
        XCTAssertFalse(service.store.isPresent(other))
        XCTAssertEqual(mock.blobCalls, 0)
    }

    func testSwappedBlobLeavesThePackAbsent() async throws {
        let (mock, id) = try mock()
        mock.swapFirstBlob = true
        let service = makeService(mock)
        let present1 = await service.ensurePresent(id)
        XCTAssertFalse(present1)
        XCTAssertFalse(service.store.isPresent(id))
        XCTAssertEqual(service.installedGeneration, 0)
    }

    // MARK: - Coalescing and backoff

    func testConcurrentAskersShareOneFetch() async throws {
        let (mock, id) = try mock()
        let service = makeService(mock)
        async let a = service.ensurePresent(id)
        async let b = service.ensurePresent(id)
        async let c = service.ensurePresent(id)
        let results = await [a, b, c]
        XCTAssertEqual(results, [true, true, true])
        XCTAssertEqual(mock.manifestCalls, 1)
        XCTAssertEqual(mock.blobCalls, 1)
    }

    /// Mutation: drop the backoff check in `ensurePresent` — the second call fetches again
    /// and `manifestCalls` becomes 2.
    func testFailureBacksOffThenRetries() async throws {
        let (mock, id) = try mock()
        mock.failBlobs = true
        let service = makeService(mock)

        let present1 = await service.ensurePresent(id)
        XCTAssertFalse(present1)
        XCTAssertEqual(mock.manifestCalls, 1)
        let present2 = await service.ensurePresent(id)
        XCTAssertFalse(present2, "inside the backoff window")
        XCTAssertEqual(mock.manifestCalls, 1, "no fetch inside the window")

        clock = clock.addingTimeInterval(StickerService.firstRetry + 1)
        mock.failBlobs = false
        let present3 = await service.ensurePresent(id)
        XCTAssertTrue(present3)
        XCTAssertEqual(mock.manifestCalls, 2)
        XCTAssertTrue(service.store.isPresent(id))
    }

    func testBackoffDoublesUpToTheCeiling() async throws {
        let (mock, id) = try mock()
        mock.failBlobs = true
        let service = makeService(mock)
        var expected = StickerService.firstRetry
        for _ in 0..<6 {
            let present1 = await service.ensurePresent(id)
        XCTAssertFalse(present1)
            // Just inside: still held. Just past: retried.
            clock = clock.addingTimeInterval(expected - 1)
            let callsBefore = mock.manifestCalls
            _ = await service.ensurePresent(id)
            XCTAssertEqual(mock.manifestCalls, callsBefore, "held at \(expected)s")
            clock = clock.addingTimeInterval(2)
            expected = min(expected * 2, StickerService.maxRetry)
        }
    }

    // MARK: - Install / uninstall

    func testInstallMarksInstalledAndUninstallKeepsThePack() async throws {
        let (mock, id) = try mock()
        let service = makeService(mock)
        try await service.install(id)
        XCTAssertEqual(service.store.installedPacks(), [id])
        try service.uninstall(id)
        XCTAssertEqual(service.store.installedPacks(), [])
        XCTAssertTrue(service.store.isPresent(id), "history that references it must keep resolving")
    }
}
