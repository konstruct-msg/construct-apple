//
//  StickerPackTests.swift
//  ConstructMessengerTests
//
//  A pack's identity is the hash of its canonical bytes, and this client must compute those
//  bytes the way the publisher does — or every real pack is rejected, silently, as "pack_id
//  mismatch". `construct-protos/conformance/knst_sticker_pack.json` fixes them on the fixture
//  pack whose files sit in Fixtures/Stickers/pack/.
//

import CryptoKit
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class StickerPackTests: XCTestCase {

    private struct Vector: Decodable {
        struct Entry: Decodable {
            let sha256: String
            let emoji: String
            let width: UInt32
            let height: UInt32
            let byteLen: UInt32
            enum CodingKeys: String, CodingKey { case sha256, emoji, width, height; case byteLen = "byte_len" }
        }
        struct Manifest: Decodable { let title: String; let publisher: String; let stickers: [Entry] }
        let manifest: Manifest
        let canonicalHex: String
        let packIdHex: String
        let manifestHex: String
        enum CodingKeys: String, CodingKey {
            case manifest
            case canonicalHex = "canonical_hex"
            case packIdHex = "pack_id_hex"
            case manifestHex = "manifest_hex"
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private var fixtureDir: URL {
        repoRoot.appendingPathComponent("ConstructMessengerTests/Fixtures/Stickers/pack")
    }

    private func vector() throws -> Vector {
        let url = repoRoot.appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_sticker_pack.json")
        let v = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(v.manifest.stickers.count, 2, "vector looks truncated")
        return v
    }

    private func manifestBytes() throws -> Data {
        try Data(contentsOf: fixtureDir.appendingPathComponent("manifest.pb"))
    }

    private func freshStore() -> StickerPackStore {
        StickerPackStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("sticker-packs-\(UUID().uuidString)", isDirectory: true))
    }

    private func blobReader(_ dir: URL) -> (StickerPack.Entry) throws -> Data? {
        { entry in try? Data(contentsOf: dir.appendingPathComponent(entry.sha256.hexString + ".webp")) }
    }

    // MARK: - Canonical bytes

    /// Built from the vector's fields by this client's serializer, the canonical bytes and the
    /// pack id are the vector's. This is the cross-implementation agreement.
    func testCanonicalBytesAndPackIdMatchTheVector() throws {
        let v = try vector()
        var m = Shared_Proto_Messaging_V1_StickerPackManifest()
        m.title = v.manifest.title
        m.publisher = v.manifest.publisher
        m.stickers = v.manifest.stickers.map { e in
            Shared_Proto_Messaging_V1_StickerEntry.with {
                $0.sha256 = Data(hexString: e.sha256)
                $0.emoji = e.emoji
                $0.width = e.width
                $0.height = e.height
                $0.byteLen = e.byteLen
            }
        }
        XCTAssertEqual(try StickerPack.canonicalBytes(of: m).hexString, v.canonicalHex)
        XCTAssertEqual(try StickerPack.packId(of: m).hexString, v.packIdHex)

        // And with pack_id set, clearing it gives the same canonical bytes — the identity does
        // not depend on whether the manifest already knows it.
        m.packID = Data(hexString: v.packIdHex)
        XCTAssertEqual(try StickerPack.canonicalBytes(of: m).hexString, v.canonicalHex)
        XCTAssertEqual(try m.serializedData().hexString, v.manifestHex)
    }

    /// The fixture file in the test bundle is the vector's manifest, byte for byte.
    func testFixtureManifestIsTheVectorsBytes() throws {
        XCTAssertEqual(try manifestBytes().hexString, try vector().manifestHex)
    }

    // MARK: - Verify

    func testFixtureVerifiesAsUnsignedOnly() throws {
        let bytes = try manifestBytes()
        let pack = try StickerPack.verify(manifestBytes: bytes, allowUnsigned: true)
        XCTAssertEqual(pack.id.hex, try vector().packIdHex)
        XCTAssertEqual(pack.stickers.count, 4)
        XCTAssertEqual(pack.stickers.map(\.emoji), ["🔵", "🟥", "🔺", "🟡"])

        XCTAssertThrowsError(try StickerPack.verify(manifestBytes: bytes)) {
            XCTAssertEqual($0 as? StickerPack.VerifyError, .unsigned)
        }
    }

    /// A manifest whose pack_id is not the hash of its own bytes is refused before the entries
    /// are looked at — a server that edits one emoji, or one hash, has made a different pack.
    func testTamperedManifestFailsOnPackId() throws {
        var m = try Shared_Proto_Messaging_V1_StickerPackManifest(serializedBytes: try manifestBytes())
        m.stickers[1].emoji = "🟩"
        XCTAssertThrowsError(try StickerPack.verify(manifestBytes: try m.serializedData(), allowUnsigned: true)) {
            XCTAssertEqual($0 as? StickerPack.VerifyError, .packIdMismatch)
        }
    }

    /// A self-consistent manifest that describes something that is not a sticker is refused on
    /// the entry: the hash proves the publisher meant it, not that it is allowed.
    func testWellHashedButOversizedEntryIsRefused() throws {
        var m = try Shared_Proto_Messaging_V1_StickerPackManifest(serializedBytes: try manifestBytes())
        m.stickers[2].byteLen = UInt32(StickerImageRules.maxBytes + 1)
        m.packID = try StickerPack.packId(of: m)
        XCTAssertThrowsError(try StickerPack.verify(manifestBytes: try m.serializedData(), allowUnsigned: true)) {
            XCTAssertEqual($0 as? StickerPack.VerifyError, .badEntry(index: 2))
        }
    }

    func testReferenceCarriesTheEntrysEmoji() throws {
        let pack = try StickerPack.verify(manifestBytes: try manifestBytes(), allowUnsigned: true)
        let ref = try XCTUnwrap(pack.reference(at: 3))
        XCTAssertEqual(ref.pack, pack.id)
        XCTAssertEqual(ref.index, 3)
        XCTAssertEqual(ref.emoji, "🟡")
        XCTAssertNil(pack.reference(at: 4))
    }

    // MARK: - Store

    func testInstallMakesThePackPresentAndResolvable() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let bytes = try manifestBytes()
        let pack = try StickerPack.verify(manifestBytes: bytes, allowUnsigned: true)

        XCTAssertFalse(store.isPresent(pack.id))
        try store.install(pack, manifestBytes: bytes, blobBytes: blobReader(fixtureDir))
        XCTAssertTrue(store.isPresent(pack.id))
        XCTAssertEqual(store.pack(pack.id), pack)

        let ref = try XCTUnwrap(pack.reference(at: 0))
        let blob = try XCTUnwrap(store.blob(for: ref))
        XCTAssertEqual(Data(SHA256.hash(data: blob)), pack.stickers[0].sha256)
        XCTAssertTrue(try WebPHeader.parse(blob).isStickerCanvas)
    }

    /// One blob short: nothing is present. The manifest is written last, and only after every
    /// blob passed, so a pack is never half there.
    func testMissingBlobLeavesThePackAbsent() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let bytes = try manifestBytes()
        let pack = try StickerPack.verify(manifestBytes: bytes, allowUnsigned: true)
        let missing = pack.stickers[2].sha256

        XCTAssertThrowsError(try store.install(pack, manifestBytes: bytes) { entry in
            entry.sha256 == missing ? nil : try self.blobReader(self.fixtureDir)(entry)
        }) {
            XCTAssertEqual($0 as? StickerPackStore.InstallError, .blobMissing(index: 2))
        }
        XCTAssertFalse(store.isPresent(pack.id))
        XCTAssertNil(store.blob(for: try XCTUnwrap(pack.reference(at: 0))), "present blobs are unreachable through an absent pack")
    }

    /// The right file under the wrong hash — the server's bytes do not match the signed
    /// manifest — is refused by the blob store and aborts the install.
    func testSwappedBlobIsRejected() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let bytes = try manifestBytes()
        let pack = try StickerPack.verify(manifestBytes: bytes, allowUnsigned: true)
        let reader = blobReader(fixtureDir)

        XCTAssertThrowsError(try store.install(pack, manifestBytes: bytes) { entry in
            // Serve sticker 1's bytes where sticker 0's were promised.
            entry.sha256 == pack.stickers[0].sha256 ? try reader(pack.stickers[1]) : try reader(entry)
        }) {
            XCTAssertEqual($0 as? StickerPackStore.InstallError, .blobRejected(index: 0))
        }
        XCTAssertFalse(store.isPresent(pack.id))
    }

    func testInstalledSetAndRecentsRoundTrip() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let bytes = try manifestBytes()
        let pack = try StickerPack.verify(manifestBytes: bytes, allowUnsigned: true)
        try store.install(pack, manifestBytes: bytes, blobBytes: blobReader(fixtureDir))

        try store.setInstalled(pack.id, true)
        XCTAssertEqual(store.installedPacks(), [pack.id])
        try store.setInstalled(pack.id, false)
        XCTAssertEqual(store.installedPacks(), [])

        let a = try XCTUnwrap(pack.reference(at: 0))
        let b = try XCTUnwrap(pack.reference(at: 1))
        try store.recordUsed(a)
        try store.recordUsed(b)
        try store.recordUsed(a)
        XCTAssertEqual(store.recent(), [a, b], "newest first, no duplicates")

        for i in 0..<(StickerPackStore.recentLimit + 5) {
            try store.recordUsed(try XCTUnwrap(StickerReference(pack: pack.id, index: UInt32(i), emoji: "x")))
        }
        XCTAssertEqual(store.recent().count, StickerPackStore.recentLimit)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    init(hexString: String) {
        var out = Data(capacity: hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            out.append(UInt8(hexString[i..<j], radix: 16)!)
            i = j
        }
        self = out
    }
}
