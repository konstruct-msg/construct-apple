//
//  ThumbnailStoreTests.swift
//  ConstructMessengerTests
//
//  The incident, device 2026-08-11 15:38:44 — measured at launch by UserDefaultsFootprint:
//
//      USERDEFAULTS: total=37785KB keys=1145 limit=4096KB OVER-LIMIT
//      USERDEFAULTS:   14945KB  message_thumbnail_*    (426 key(s))
//      USERDEFAULTS:   14945KB  message_thumbnail_*_0  (426 key(s))
//
//  JPEG thumbnails in NSUserDefaults, index 0 written twice, nine times the CFPreferences limit.
//  Past that limit CFPreferences refuses writes for everything else in the domain.
//

import XCTest
@testable import Construct_Messenger

final class ThumbnailStoreTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ThumbnailStore!

    private let messageId = "d6f36cd7-de0d-420e-b59d-c42637e59089"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbs-\(UUID().uuidString)", isDirectory: true)
        suiteName = "thumbnail-store-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = ThumbnailStore(directory: directory, defaults: defaults)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Reading the two key spellings that existed

    func testLegacyUnindexedKeyIsReadAsIndexZero() {
        let parsed = ThumbnailKey.parse(defaultsKey: "message_thumbnail_\(messageId)")
        XCTAssertEqual(parsed?.messageId, messageId)
        XCTAssertEqual(parsed?.index, 0)
    }

    func testIndexedKeyIsParsed() {
        let parsed = ThumbnailKey.parse(defaultsKey: "message_thumbnail_\(messageId)_3")
        XCTAssertEqual(parsed?.messageId, messageId)
        XCTAssertEqual(parsed?.index, 3)
    }

    /// The migration walks the whole domain. Eating a key it does not own would delete a session
    /// flag or a stream cursor, which is a far worse outcome than the leak it is fixing.
    func testUnrelatedKeysAreNotClaimed() {
        XCTAssertNil(ThumbnailKey.parse(defaultsKey: "construct.stream.cursor"))
        XCTAssertNil(ThumbnailKey.parse(defaultsKey: "session_expires"))
        XCTAssertNil(ThumbnailKey.parse(defaultsKey: "message_thumbnail_"))
    }

    // MARK: - Filenames

    /// A message id becomes a path component. It is a UUID everywhere in this app, but the store
    /// must not be the reason a hostile id could write outside its directory.
    func testFilenameCannotEscapeTheDirectory() {
        let name = ThumbnailKey.filename(messageId: "../../Library/Preferences/evil", index: 0)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("."))
    }

    /// Deleting one message must not take another message's thumbnails with it.
    func testBelongsToMessageDoesNotMatchADifferentMessage() {
        let other = "8b23f2f6-69c4-4300-b382-f610ecfa8bbd"
        let file = ThumbnailKey.filename(messageId: messageId, index: 1)
        XCTAssertTrue(ThumbnailKey.belongsToMessage(file: file, messageId: messageId))
        XCTAssertFalse(ThumbnailKey.belongsToMessage(file: file, messageId: other))

        // The separator is what makes this safe, not the ids being long: without the trailing
        // underscore, deleting "abc" would take "abcd" with it. Two unrelated UUIDs would never
        // have caught that.
        XCTAssertFalse(
            ThumbnailKey.belongsToMessage(
                file: ThumbnailKey.filename(messageId: "abcd", index: 0),
                messageId: "abc"
            )
        )
    }

    // MARK: - Migration

    func testMigrationDrainsTheDomainAndKeepsTheImage() throws {
        let image = Data(repeating: 0xAB, count: 35_000)
        // Exactly what the device carried: the indexed key and its index-0 duplicate.
        defaults.set(image, forKey: "message_thumbnail_\(messageId)_0")
        defaults.set(image, forKey: "message_thumbnail_\(messageId)")

        let result = store.migrateFromUserDefaults()

        XCTAssertEqual(result.keys, 2)
        XCTAssertNil(defaults.data(forKey: "message_thumbnail_\(messageId)_0"))
        XCTAssertNil(defaults.data(forKey: "message_thumbnail_\(messageId)"))
        XCTAssertEqual(store.load(for: messageId, at: 0), image, "the preview must survive the move")
    }

    func testMigrationLeavesUnrelatedKeysAlone() {
        defaults.set("1786445681284-0", forKey: "construct.stream.cursor")
        defaults.set(Data(repeating: 1, count: 10), forKey: "message_thumbnail_\(messageId)_0")

        store.migrateFromUserDefaults()

        XCTAssertEqual(defaults.string(forKey: "construct.stream.cursor"), "1786445681284-0")
    }

    /// Bulk migration alone would still leave anything written between launches. Read-path
    /// migration alone is the mistake that let OutgoingWirePayloadStore accumulate — a rule that
    /// only runs when someone asks for that key never reaches what nobody asks for. Both exist.
    func testLoadFallsBackToLegacyKeyAndDrainsIt() {
        let image = Data(repeating: 0x7F, count: 128)
        defaults.set(image, forKey: "message_thumbnail_\(messageId)")

        XCTAssertEqual(store.load(for: messageId, at: 0), image)
        XCTAssertNil(defaults.data(forKey: "message_thumbnail_\(messageId)"),
                     "reading it should have moved it out of UserDefaults")
    }

    // MARK: - Round trip

    func testStoreAndLoadAcrossIndices() {
        let first = Data(repeating: 1, count: 64)
        let second = Data(repeating: 2, count: 64)
        store.store(first, for: messageId, at: 0)
        store.store(second, for: messageId, at: 1)

        XCTAssertEqual(store.load(for: messageId, at: 0), first)
        XCTAssertEqual(store.load(for: messageId, at: 1), second)
    }

    func testRemoveTakesEveryIndexOfThatMessageOnly() {
        let other = "8b23f2f6-69c4-4300-b382-f610ecfa8bbd"
        store.store(Data(repeating: 1, count: 16), for: messageId, at: 0)
        store.store(Data(repeating: 2, count: 16), for: messageId, at: 1)
        store.store(Data(repeating: 3, count: 16), for: other, at: 0)

        store.remove(for: messageId)

        XCTAssertNil(store.load(for: messageId, at: 0))
        XCTAssertNil(store.load(for: messageId, at: 1))
        XCTAssertNotNil(store.load(for: other, at: 0), "a different message must be untouched")
    }

    /// The duplicate write is the reason the top two rows of the report were identical. One image,
    /// one file.
    func testIndexZeroIsWrittenOnce() throws {
        store.store(Data(repeating: 9, count: 32), for: messageId, at: 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1, "found \(files)")
    }
}
