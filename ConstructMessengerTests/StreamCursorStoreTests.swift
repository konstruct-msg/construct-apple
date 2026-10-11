//
//  StreamCursorStoreTests.swift
//  ConstructMessengerTests
//
//  The committed stream cursor lives in the Keychain, where the notification extension can read
//  it (construct-docs todo 124). These pin where it is written, the one move from UserDefaults,
//  and that clearing it leaves neither copy behind.
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
        XCTAssertNil(UserDefaults.standard.string(forKey: StreamCursorStore.legacyDefaultsKey))
        XCTAssertEqual(StreamCursorStore.load(), "1791716856377-0")
    }

    /// An install updated from a build that kept it in UserDefaults resumes from the same place,
    /// and the old copy is gone after the first read.
    func testACursorLeftInUserDefaultsMovesOnFirstRead() throws {
        UserDefaults.standard.set("1785495484579-0", forKey: StreamCursorStore.legacyDefaultsKey)

        XCTAssertEqual(StreamCursorStore.load(), "1785495484579-0")
        XCTAssertNil(UserDefaults.standard.string(forKey: StreamCursorStore.legacyDefaultsKey))
        let moved = try XCTUnwrap(KeychainManager.shared.loadData(forKey: StreamCursorStore.keychainAccount))
        XCTAssertEqual(String(decoding: moved, as: UTF8.self), "1785495484579-0")
    }

    /// Sign-out and wipe call `clear`: the next account must not resume this one's stream from
    /// either place.
    func testClearRemovesBothCopies() {
        StreamCursorStore.save("1791716856377-0")
        UserDefaults.standard.set("1785495484579-0", forKey: StreamCursorStore.legacyDefaultsKey)

        StreamCursorStore.clear()

        XCTAssertNil(KeychainManager.shared.loadData(forKey: StreamCursorStore.keychainAccount))
        XCTAssertNil(UserDefaults.standard.string(forKey: StreamCursorStore.legacyDefaultsKey))
        XCTAssertNil(StreamCursorStore.load())
    }
}
