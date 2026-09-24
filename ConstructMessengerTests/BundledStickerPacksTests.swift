//
//  BundledStickerPacksTests.swift
//  ConstructMessengerTests
//
//  Two things: the app bundle really carries a whole pack (every blob the manifest names, at
//  the name the loader looks for — the synchronized group flattens the folder, and a file that
//  landed elsewhere would be a pack that verifies and then fails on its first blob), and
//  seeding is once, respects an uninstall, and trusts nothing for being in the bundle.
//

import CryptoKit
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

@MainActor
final class BundledStickerPacksTests: XCTestCase {

    // MARK: - What ships

    func testAppBundleCarriesEveryBlobItsPacksName() throws {
        let manifests = Bundle.main.manifests()
        XCTAssertFalse(manifests.isEmpty, "no sticker-pack-*.pb in the app bundle")
        for bytes in manifests {
            let pack = try StickerPack.verify(manifestBytes: bytes, allowUnsigned: true, trustedKeys: BundleSigningTrust.trustedKeys())
            XCTAssertFalse(pack.stickers.isEmpty)
            for (i, entry) in pack.stickers.enumerated() {
                let data = try XCTUnwrap(Bundle.main.blob(entry.sha256), "\(pack.title) sticker \(i): blob missing from the bundle")
                XCTAssertEqual(Data(SHA256.hash(data: data)), entry.sha256, "\(pack.title) sticker \(i): bytes do not hash to the manifest's entry")
                XCTAssertEqual(data.count, entry.byteLen)
                XCTAssertTrue(try WebPHeader.parse(data).isStickerCanvas, "\(pack.title) sticker \(i): not a static 512×512 WebP")
            }
        }
    }

    /// Release seeds only what the pinned keys sign. Verified here with `allowUnsigned: false`
    /// against `BundleSigningTrust.trustedKeys()` — the same call the seeding makes — so the
    /// DEBUG exemption cannot hide a shipped pack that release would refuse.
    func testShippedPacksAreSignedByAPinnedKey() throws {
        for bytes in Bundle.main.manifests() {
            XCTAssertNoThrow(
                try StickerPack.verify(manifestBytes: bytes, allowUnsigned: false, trustedKeys: BundleSigningTrust.trustedKeys()),
                "a bundled pack release would refuse — sign it with the production key (sticker-publish --dry-run --out)"
            )
        }
    }

    // MARK: - Seeding

    private static let signingKey = Curve25519.Signing.PrivateKey()

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Stickers/pack")
    }

    private final class Source: BundledPackSource {
        var manifestList: [Data] = []
        var blobs: [Data: Data] = [:]
        func manifests() -> [Data] { manifestList }
        func blob(_ sha256: Data) -> Data? { blobs[sha256] }
    }

    /// The fixture pack as a bundled source: unsigned, or signed by `key`.
    private func fixtureSource(signedBy key: Curve25519.Signing.PrivateKey? = nil, dropBlob: Bool = false) throws -> (Source, StickerPackID) {
        var m = try Shared_Proto_Messaging_V1_StickerPackManifest(serializedBytes: Data(contentsOf: fixtureDir.appendingPathComponent("manifest.pb")))
        if let key { m.signature = try key.signature(for: try StickerPack.canonicalBytes(of: m)) }
        let source = Source()
        source.manifestList = [try m.serializedData()]
        for (i, entry) in m.stickers.enumerated() where !(dropBlob && i == 1) {
            let hex = entry.sha256.map { String(format: "%02x", $0) }.joined()
            source.blobs[entry.sha256] = try Data(contentsOf: fixtureDir.appendingPathComponent(hex + ".webp"))
        }
        return (source, StickerPackID(m.packID)!)
    }

    private func makeService(keys: [Curve25519.Signing.PublicKey] = []) -> (StickerService, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString)", isDirectory: true)
        let suite = "bundled-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let service = StickerService(store: StickerPackStore(root: root), fetcher: NoFetch(), trustedKeys: { keys })
        return (service, defaults)
    }

    private struct NoFetch: StickerPackFetching {
        func manifestBytes(for pack: StickerPackID) async throws -> Data { throw URLError(.notConnectedToInternet) }
        func blobs(for pack: StickerPackID, have: [Data], onBlob: @escaping @Sendable (Data, Data) throws -> Void) async throws { throw URLError(.notConnectedToInternet) }
        func catalog() async throws -> [Shared_Proto_Services_V1_StickerPackSummary] { [] }
        func blob(_ sha256: Data) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    func testSeedsOnceAndRespectsAnUninstall() throws {
        let (source, id) = try fixtureSource()
        let (service, defaults) = makeService()
        let gen0 = service.installedGeneration

        XCTAssertEqual(service.seedBundledPacks(from: source, defaults: defaults), [id])
        XCTAssertTrue(service.store.isPresent(id))
        XCTAssertEqual(service.store.installedPacks(), [id])
        XCTAssertEqual(service.installedGeneration, gen0 + 1)

        XCTAssertEqual(service.seedBundledPacks(from: source, defaults: defaults), [], "a second launch seeds nothing")
        XCTAssertEqual(service.installedGeneration, gen0 + 1)

        try service.uninstall(id)
        XCTAssertEqual(service.store.installedPacks(), [])
        XCTAssertEqual(service.seedBundledPacks(from: source, defaults: defaults), [], "an uninstall stands on the next launch")
        XCTAssertEqual(service.store.installedPacks(), [])
    }

    func testSignedPackSeedsAgainstItsKeyAndNotAnother() throws {
        let (source, id) = try fixtureSource(signedBy: Self.signingKey)

        let (trusting, d1) = makeService(keys: [Self.signingKey.publicKey])
        XCTAssertEqual(trusting.seedBundledPacks(from: source, defaults: d1), [id])

        let (other, d2) = makeService(keys: [Curve25519.Signing.PrivateKey().publicKey])
        XCTAssertEqual(other.seedBundledPacks(from: source, defaults: d2), [], "a signature by a key we do not pin is refused, bundle or not")
        XCTAssertFalse(other.store.isPresent(id))
        XCTAssertNil(d2.stringArray(forKey: BundledStickerPacks.seededDefaultsKey), "a refused pack is not remembered as seeded")
    }

    func testMissingBlobLeavesThePackAbsentAndUnseeded() throws {
        let (source, id) = try fixtureSource(dropBlob: true)
        let (service, defaults) = makeService()
        XCTAssertEqual(service.seedBundledPacks(from: source, defaults: defaults), [])
        XCTAssertFalse(service.store.isPresent(id), "the manifest is written last; no blob, no pack")
        XCTAssertNil(defaults.stringArray(forKey: BundledStickerPacks.seededDefaultsKey))
    }

    func testAlreadyPresentPackIsMarkedInstalledWithoutRewriting() throws {
        // A pack fetched from a peer before the app version that bundles it: present, not
        // installed. Seeding lists it in the picker and does not touch the blobs.
        let (source, id) = try fixtureSource()
        let (service, defaults) = makeService()
        let pack = try StickerPack.verify(manifestBytes: source.manifestList[0], allowUnsigned: true)
        try service.store.install(pack, manifestBytes: source.manifestList[0]) { source.blob($0.sha256) }
        XCTAssertEqual(service.store.installedPacks(), [])

        XCTAssertEqual(service.seedBundledPacks(from: source, defaults: defaults), [id])
        XCTAssertEqual(service.store.installedPacks(), [id])
    }

    // MARK: - Retired

    /// Fresh device: a retired pack is present for the messages that name it, and not listed.
    /// Mutation that reddens it: seed a retired pack like any other (drop the `retired` branch).
    func testRetiredPackIsPresentButNotInThePicker() throws {
        let (source, id) = try fixtureSource()
        let (service, defaults) = makeService()

        XCTAssertEqual(service.seedBundledPacks(from: source, defaults: defaults, retired: [id.hex]), [])
        XCTAssertTrue(service.store.isPresent(id), "an old message must still render from the bundle")
        XCTAssertEqual(service.store.installedPacks(), [])
    }

    /// Existing device: the pack seeded by an older build is taken off the picker, and its blobs
    /// stay. Mutation that reddens it: skip `setInstalled(false)` for a pack already present.
    func testRetiringTakesAnAlreadySeededPackOffThePicker() throws {
        let (source, id) = try fixtureSource()
        let (service, defaults) = makeService()
        XCTAssertEqual(service.seedBundledPacks(from: source, defaults: defaults), [id])
        let gen = service.installedGeneration

        XCTAssertEqual(service.seedBundledPacks(from: source, defaults: defaults, retired: [id.hex]), [])
        XCTAssertEqual(service.store.installedPacks(), [])
        XCTAssertTrue(service.store.isPresent(id))
        XCTAssertEqual(service.installedGeneration, gen + 1, "the picker must reload to drop it")
    }

    /// Retiring happens once: a person who installs the pack again keeps it on every later launch.
    /// Mutation that reddens it: not remembering the retired id (uninstall on every launch).
    func testAReinstalledRetiredPackStaysInstalled() throws {
        let (source, id) = try fixtureSource()
        let (service, defaults) = makeService()
        _ = service.seedBundledPacks(from: source, defaults: defaults, retired: [id.hex])
        try service.store.setInstalled(id, true)

        _ = service.seedBundledPacks(from: source, defaults: defaults, retired: [id.hex])
        XCTAssertEqual(service.store.installedPacks(), [id])
    }
}
