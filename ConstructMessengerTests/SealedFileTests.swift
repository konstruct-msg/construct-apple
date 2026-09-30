//
//  SealedFileTests.swift
//  ConstructMessengerTests
//
//  Media and thumbnails at rest are sealed in chunks under `LocalStoreKey`.
//  `decisions/macos-store-encrypted-at-rest.md` (variant B)
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class SealedFileTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)
    private let chunk = SealedFile.chunkSize

    private func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sealed-\(UUID().uuidString)")
    }

    // MARK: - Format

    func testEverySizeRoundTripsAndItsClearSizeIsKnownFromTheFileSize() throws {
        for size in [0, 1, chunk - 1, chunk, chunk + 1, 3 * chunk, 3 * chunk + 17] {
            let clear = bytes(size)
            let sealed = try SealedFile.seal(clear, under: key, context: "media/x")
            XCTAssertEqual(try SealedFile.open(sealed, under: key, context: "media/x"), clear, "size \(size)")
            XCTAssertEqual(SealedFile.plaintextSize(ofSealedFileSize: UInt64(sealed.count)), UInt64(size), "size \(size)")
            XCTAssertNil(sealed.range(of: bytes(min(size, 64)).prefix(64)).flatMap { size >= 16 ? $0 : nil },
                         "no clear run of the input in the file, size \(size)")
        }
    }

    func testStreamingWritesWhatWholeSealingOpens() throws {
        let clear = bytes(2 * chunk + 1000)
        let writer = try SealedFile.Writer(key: key, context: "media/y")
        var sealed = writer.header
        for piece in stride(from: 0, to: clear.count, by: 5000) {
            sealed.append(try writer.append(clear.subdata(in: piece..<min(piece + 5000, clear.count))))
        }
        sealed.append(try writer.finish())
        XCTAssertEqual(try SealedFile.open(sealed, under: key, context: "media/y"), clear)
    }

    // MARK: - What does not open

    func testAnotherContextOrKeyDoesNotOpen() throws {
        let sealed = try SealedFile.seal(bytes(100), under: key, context: "media/a")
        XCTAssertThrowsError(try SealedFile.open(sealed, under: key, context: "media/b"))
        XCTAssertThrowsError(try SealedFile.open(sealed, under: SymmetricKey(size: .bits256), context: "media/a"))
    }

    /// Mutation: leave the final flag out of the associated data — a file cut after a full chunk
    /// opens as a shorter file and this reddens.
    func testAFileCutAtAChunkBoundaryDoesNotReadAsShorter() throws {
        let sealed = try SealedFile.seal(bytes(2 * chunk + 5), under: key, context: "media/c")
        let cut = sealed.prefix(SealedFile.headerSize + chunk + SealedFile.tagSize)
        XCTAssertThrowsError(try SealedFile.open(cut, under: key, context: "media/c"))
    }

    /// Mutation: take the chunk index out of the nonce and associated data — swapped chunks open.
    func testSwappedChunksDoNotOpen() throws {
        let sealed = try SealedFile.seal(bytes(3 * chunk), under: key, context: "media/d")
        let h = SealedFile.headerSize, c = chunk + SealedFile.tagSize
        var swapped = sealed.prefix(h)
        swapped.append(sealed.subdata(in: (h + c)..<(h + 2 * c)))
        swapped.append(sealed.subdata(in: h..<(h + c)))
        swapped.append(sealed.subdata(in: (h + 2 * c)..<sealed.count))
        XCTAssertThrowsError(try SealedFile.open(swapped, under: key, context: "media/d"))
    }

    // MARK: - Files

    /// A file from before sealing is read and sealed where it lies. Mutation: return it without
    /// sealing — the clear file stays and this reddens.
    func testAClearFileIsSealedTheFirstTimeItIsRead() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clear = bytes(chunk + 3)
        try clear.write(to: url)

        XCTAssertEqual(AtRestFiles.read(url, context: "media/e"), clear)
        XCTAssertTrue(SealedFile.isSealed(fileAt: url))
        XCTAssertEqual(AtRestFiles.read(url, context: "media/e"), clear)
        XCTAssertEqual(AtRestFiles.clearSize(of: url), UInt64(clear.count))
    }

    func testSealingInPlaceStreamsAndChunksReadItBack() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clear = bytes(3 * chunk + 11)
        try clear.write(to: url)

        XCTAssertTrue(AtRestFiles.sealInPlace(url, context: "media/f"))
        XCTAssertTrue(SealedFile.isSealed(fileAt: url))
        XCTAssertFalse(AtRestFiles.sealInPlace(url, context: "media/f"), "sealed once")

        var read = Data()
        for piece in try AtRestFiles.chunks(of: url, context: "media/f") { read.append(piece) }
        XCTAssertEqual(read, clear)
    }
}
