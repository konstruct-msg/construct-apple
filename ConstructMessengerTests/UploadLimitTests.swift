//
//  UploadLimitTests.swift
//  ConstructMessengerTests
//
//  The attach-time limit is the one the core seals for. Until 2026-10-18 a 200 MB document or a
//  500 MB file passed here and failed later at sealing or at the server.
//

import XCTest
@testable import Construct_Messenger

final class UploadLimitTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadLimitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A sparse file: its size is set, nothing is written.
    private func file(_ name: String, size: Int64) throws -> URL {
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    /// Mutation: give documents their old 200 MB limit — the one-byte-over case reddens.
    func testADocumentOverWhatTheCoreSealsIsRefusedAtAttach() throws {
        let limit = Int64(mediaMaxPlaintextLen())
        XCTAssertEqual(try MessageValidator.validateFile(at: file("at.pdf", size: limit)), limit)
        XCTAssertThrowsError(try MessageValidator.validateFile(at: file("over.pdf", size: limit + 1)))
    }

    /// Mutation: give audio its old 100 MiB limit — the one-byte-over case reddens.
    func testAudioOverWhatTheCoreSealsIsRefusedAtAttach() throws {
        let limit = Int64(mediaMaxPlaintextLen())
        XCTAssertThrowsError(try MessageValidator.validateFile(at: file("over.m4a", size: limit + 1)))
    }
}
