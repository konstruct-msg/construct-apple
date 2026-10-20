//
//  StreamCursorStoreTests.swift
//  ConstructMessengerTests
//
//  The committed stream cursor lives in the Keychain, where the notification extension can read
//  it (construct-docs todo 124). These pin where it is written and that clearing it removes it.
//

import XCTest
@testable import Construct_Messenger

final class StreamCursorStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StreamCursorStore.clear()
    }

    override func tearDown() {
        StreamCursorStore.clear()
        super.tearDown()
    }

    /// Saved where the extension reads it, under the account it names.
    func testTheCursorIsKeptInTheKeychain() throws {
        StreamCursorStore.save("1791716856377-0")
        let stored = try XCTUnwrap(KeychainManager.shared.loadData(forKey: StreamCursorStore.keychainAccount))
        XCTAssertEqual(String(decoding: stored, as: UTF8.self), "1791716856377-0")
        XCTAssertEqual(StreamCursorStore.load(), "1791716856377-0")
    }

    /// Sign-out and wipe call `clear`: the next account must not resume this one's stream from
    /// where it stopped.
    func testClearRemovesIt() {
        StreamCursorStore.save("1791716856377-0")

        StreamCursorStore.clear()

        XCTAssertNil(KeychainManager.shared.loadData(forKey: StreamCursorStore.keychainAccount))
        XCTAssertNil(StreamCursorStore.load())
    }
}
