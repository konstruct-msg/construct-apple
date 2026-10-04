//
//  MediaBlobTests.swift
//  ConstructMessengerTests
//
//  Media blobs are sealed and opened by the core since 0.33 (`media.rs`): padded to a Padmé
//  bucket so the server sees a size class rather than the file's size. Until then this app
//  sealed them with CryptoKit, as the file exactly as it was, and Android did the same by hand.
//
//  These pin the two things the app depends on: what it wrote before still opens — the vector
//  below is CryptoKit's own output, compared with the bytes the core's test pins — and what it
//  writes now is the padded blob the core makes, not the file's size.
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class MediaBlobTests: XCTestCase {

    /// construct-core `media.rs` `LEGACY_VECTOR`: key 0x07×32, nonce 0x09×12, "konstruct".
    private static let legacyVector =
        "0909090909090909090909094ceaeae7ca82b402d45b2c4d098ff3e8d8546682abc9e5f8ab"

    private static let key = Data(repeating: 7, count: 32)

    /// The format this app wrote before 0.33 is byte-for-byte the one the core opens as legacy.
    func testCryptoKitLegacyBlobIsTheCoreVectorAndOpens() throws {
        let box = try AES.GCM.seal(
            Data("konstruct".utf8),
            using: SymmetricKey(data: Self.key),
            nonce: AES.GCM.Nonce(data: Data(repeating: 9, count: 12))
        )
        let blob = try XCTUnwrap(box.combined)
        XCTAssertEqual(blob.map { String(format: "%02x", $0) }.joined(), Self.legacyVector)

        let opened = try CryptoManager.shared.decryptMediaData(blob, with: Self.key)
        XCTAssertEqual(opened, Data("konstruct".utf8))
    }

    func testSealedBlobIsPaddedAndOpens() throws {
        let file = Data((0..<10_000).map { UInt8($0 % 251) })
        let sealed = try sealMedia(plaintext: file)

        XCTAssertEqual(sealed.key.count, 32)
        XCTAssertGreaterThan(sealed.blob.count, file.count + 28, "the blob carries padding")
        XCTAssertEqual(sealed.sha256, Data(SHA256.hash(data: sealed.blob)))
        XCTAssertEqual(try CryptoManager.shared.decryptMediaData(sealed.blob, with: sealed.key), file)
    }

    /// Two files a few bytes apart produce blobs of one size — the point of the change.
    func testNearbySizesShareABlobSize() throws {
        let a = try sealMedia(plaintext: Data(repeating: 1, count: 500_000))
        let b = try sealMedia(plaintext: Data(repeating: 1, count: 500_777))
        XCTAssertEqual(a.blob.count, b.blob.count)
    }

    /// A new blob is unreadable to the old CryptoKit path — it fails, it does not hand back a
    /// file with a tail of zeros.
    func testPaddedBlobDoesNotOpenAsLegacy() throws {
        let sealed = try sealMedia(plaintext: Data("konstruct".utf8))
        let box = try AES.GCM.SealedBox(combined: sealed.blob)
        XCTAssertThrowsError(try AES.GCM.open(box, using: SymmetricKey(data: sealed.key)))
    }

    func testWrongKeyIsRefused() throws {
        let sealed = try sealMedia(plaintext: Data("konstruct".utf8))
        XCTAssertThrowsError(
            try CryptoManager.shared.decryptMediaData(sealed.blob, with: Data(repeating: 0, count: 32))
        )
    }

    func testLargestFileIsTheServiceLimitLessOverhead() {
        XCTAssertEqual(mediaMaxPlaintextLen(), 100_000_000 - 36)
    }
}
