//
//  FileMessageContentTests.swift
//  ConstructMessengerTests
//
//  Documents are sent as they are since 2026-09-30: the `compressed` flag never reached the wire
//  (the album has no such field), so no receiver knew to inflate. The file view is built from the
//  album without it, and rows stored while it existed still read.
//

import XCTest
@testable import Construct_Messenger

final class FileMessageContentTests: XCTestCase {

    func testFileViewOfAnAlbumReadsWithoutACompressionFlag() throws {
        var item = Shared_Proto_Messaging_V1_MediaMessage()
        item.mediaID = "media-1"
        item.mimeType = "text/plain"
        item.fileSize = 14590
        item.filename = "notes.txt"
        item.encryptionKey = Data(repeating: 0x07, count: 32)
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = [item]

        let json = try XCTUnwrap(MediaWireCodec.fileJSON(from: album))
        XCTAssertFalse(json.contains("compressed"))
        let file = try JSONDecoder().decode(FileMessageContent.self, from: Data(json.utf8))
        XCTAssertEqual(file.files.map(\.filename), ["notes.txt"])
        XCTAssertEqual(file.files.first?.size, 14590)
        XCTAssertEqual(file.files.first?.mediaKey, Data(repeating: 0x07, count: 32))
    }

    func testARowStoredWithTheOldFlagStillReads() throws {
        let stored = """
        {"type":"file","caption":"","files":[{"mediaId":"m","mediaUrl":"u","mediaKey":"AAAA",\
        "mediaType":"text/plain","size":1,"hash":"00","filename":"a.txt","compressed":false}]}
        """
        let file = try JSONDecoder().decode(FileMessageContent.self, from: Data(stored.utf8))
        XCTAssertEqual(file.files.first?.filename, "a.txt")
    }
}
