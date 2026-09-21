//
//  StickerBlobStoreTests.swift
//  ConstructMessengerTests
//
//  The header parser against real files from three encoders' worth of container layouts, and
//  the store's refusal order: nothing a lying server sends reaches the cache.
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class StickerBlobStoreTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Stickers/\(name)")
        return try Data(contentsOf: url)
    }

    private func sha(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    private func freshStore() -> StickerBlobStore {
        StickerBlobStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("sticker-blobs-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: - WebPHeader

    func testParsesAllThreeContainerKinds() throws {
        XCTAssertEqual(try WebPHeader.parse(fixture("lossy_512.webp")),
                       WebPHeader(kind: .lossy, width: 512, height: 512))
        XCTAssertEqual(try WebPHeader.parse(fixture("lossless_512.webp")),
                       WebPHeader(kind: .lossless, width: 512, height: 512))
        XCTAssertEqual(try WebPHeader.parse(fixture("lossy_alpha_512.webp")),
                       WebPHeader(kind: .extended(animated: false), width: 512, height: 512))
    }

    func testWrongCanvasAndAnimationAreNotStickers() throws {
        let small = try WebPHeader.parse(fixture("lossy_alpha_256.webp"))
        XCTAssertEqual(small.width, 256)
        XCTAssertFalse(small.isStickerCanvas)

        let animated = try WebPHeader.parse(fixture("animated_512.webp"))
        XCTAssertEqual(animated, WebPHeader(kind: .extended(animated: true), width: 512, height: 512))
        XCTAssertFalse(animated.isStickerCanvas, "512×512 but animated — a separate decision, refused here")
    }

    func testHeaderOnlyIsEnoughAndGarbageIsNamed() throws {
        let full = try fixture("lossless_512.webp")
        XCTAssertEqual(try WebPHeader.parse(full.prefix(30)), try WebPHeader.parse(full))
        XCTAssertThrowsError(try WebPHeader.parse(full.prefix(20))) {
            XCTAssertEqual($0 as? WebPHeader.ParseError, .truncated)
        }
        XCTAssertThrowsError(try WebPHeader.parse(Data(repeating: 0x41, count: 40))) {
            XCTAssertEqual($0 as? WebPHeader.ParseError, .notRIFF)
        }
        var png = full
        png.replaceSubrange(8..<12, with: Data("PNG ".utf8))
        XCTAssertThrowsError(try WebPHeader.parse(png)) {
            XCTAssertEqual($0 as? WebPHeader.ParseError, .notWebP)
        }
    }

    // MARK: - StickerBlobStore

    func testPutThenGetIsTheSameBytesAtTheHashPath() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let blob = try fixture("lossy_alpha_512.webp")
        let key = sha(blob)

        XCTAssertFalse(store.contains(key))
        try store.put(blob, expecting: key)
        XCTAssertTrue(store.contains(key))
        XCTAssertEqual(store.data(for: key), blob)
        XCTAssertEqual(store.url(for: key).lastPathComponent,
                       key.map { String(format: "%02x", $0) }.joined() + ".webp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".").path + "x"),
                       "no temporaries left behind")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        XCTAssertEqual(leftovers.count, 1)
    }

    /// Hash first: bytes that are not the bytes the signed manifest named are never written,
    /// even when they are a perfectly good sticker image.
    func testHashMismatchWritesNothing() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let blob = try fixture("lossy_alpha_512.webp")
        let wrong = sha(try fixture("lossless_512.webp"))
        XCTAssertThrowsError(try store.put(blob, expecting: wrong)) {
            XCTAssertEqual($0 as? StickerBlobStore.PutError, .hashMismatch)
        }
        XCTAssertFalse(store.contains(wrong))
        XCTAssertFalse(store.contains(sha(blob)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path), "nothing was even created")
    }

    /// Right hash, wrong picture: a 256×256 or an animation with a matching hash is still
    /// refused — the manifest's hash proves the server sent what it promised, not that what
    /// it promised is a sticker.
    func testNotAStickerImageIsRefusedEvenWithTheRightHash() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        for name in ["lossy_alpha_256.webp", "animated_512.webp"] {
            let blob = try fixture(name)
            XCTAssertThrowsError(try store.put(blob, expecting: sha(blob)), name) {
                XCTAssertEqual($0 as? StickerBlobStore.PutError, .notAStickerImage, name)
            }
            XCTAssertFalse(store.contains(sha(blob)), name)
        }
    }

    func testOversizeIsRefusedBeforeHashing() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let big = Data(repeating: 0, count: StickerImageRules.maxBytes + 1)
        XCTAssertThrowsError(try store.put(big, expecting: sha(big))) {
            XCTAssertEqual($0 as? StickerBlobStore.PutError, .tooLarge(StickerImageRules.maxBytes + 1))
        }
    }

    func testPutOfAnExistingHashIsANoOp() throws {
        let store = freshStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let blob = try fixture("lossless_512.webp")
        try store.put(blob, expecting: sha(blob))
        try store.put(blob, expecting: sha(blob))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path).count, 1)
    }
}
