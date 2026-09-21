//
//  StickerFixturePackTests.swift
//  ConstructMessengerTests
//
//  The embedded DEBUG fixture and the test-bundle fixture are the same bytes. Two copies of one
//  pack exist for a reason (the app cannot bundle files without shipping them in release); this
//  is what keeps the reason from becoming a drift.
//

import XCTest
@testable import Construct_Messenger

#if DEBUG
final class StickerFixturePackTests: XCTestCase {

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Stickers/pack")
    }

    func testEmbeddedBytesAreTheTestFixture() throws {
        let manifest = try Data(contentsOf: fixtureDir.appendingPathComponent("manifest.pb"))
        XCTAssertEqual(StickerFixturePack.manifestBytes, manifest)

        let files = try FileManager.default.contentsOfDirectory(atPath: fixtureDir.path).filter { $0.hasSuffix(".webp") }
        XCTAssertEqual(Set(files.map { String($0.dropLast(5)) }), Set(StickerFixturePack.blobsHex.keys),
                       "run scripts/embed_sticker_fixture.py")
        for file in files {
            let onDisk = try Data(contentsOf: fixtureDir.appendingPathComponent(file))
            XCTAssertEqual(StickerFixturePack.blobsHex[String(file.dropLast(5))], onDisk.map { String(format: "%02x", $0) }.joined(), file)
        }
    }

    func testInstallMakesTheFixturePresentAndInstalled() throws {
        let store = StickerPackStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("sticker-fixture-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.root) }

        let pack = try StickerFixturePack.install(into: store)
        XCTAssertTrue(store.isPresent(pack.id))
        XCTAssertEqual(store.installedPacks(), [pack.id])
        XCTAssertEqual(pack.stickers.count, 4)
        for i in 0..<4 {
            XCTAssertNotNil(store.blob(for: try XCTUnwrap(pack.reference(at: i))), "sticker \(i)")
        }
        // Idempotent.
        XCTAssertNoThrow(try StickerFixturePack.install(into: store))
        XCTAssertEqual(store.installedPacks(), [pack.id])
    }
}
#endif
