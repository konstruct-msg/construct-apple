//
//  NotesLiveInTheEncryptedStoreTests.swift
//  Construct Messenger
//
//  Notes were JSON in `UserDefaults`, a plain file, under a key no wipe knew: the previous owner's
//  notes outlived the account (todo/278). Real store, real keys.
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class NotesLiveInTheEncryptedStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var session: LocalStoreSession!
    private var keyValue: any KeyValueStore { LocalStoreKeyValueStore(session: session) }

    override func setUpWithError() throws {
        suite = "NotesLiveInTheEncryptedStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        session = LocalStoreSession.inMemoryForTesting()
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func plainList(_ texts: [String]) throws -> Data {
        try JSONEncoder().encode(texts.map { NoteItem(id: UUID(), text: $0, createdAt: Date(timeIntervalSince1970: 1_700_000_000)) })
    }

    // MARK: - On disk

    /// The promise itself. Mutation: keep the list in `UserDefaults` — this reddens.
    func testANoteIsNotReadableInTheStoreFileOrInDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("construct.db").path
        let session = try LocalStoreSession.open(at: URL(fileURLWithPath: path), key: SymmetricKey(size: .bits256)).get()

        _ = try NotesStore.add("Unmistakable-Note", in: LocalStoreKeyValueStore(session: session))

        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        if let wal = try? Data(contentsOf: URL(fileURLWithPath: path + "-wal")) { bytes.append(wal) }
        XCTAssertNil(bytes.range(of: Data("Unmistakable".utf8)))
        XCTAssertEqual(try NotesStore.all(in: LocalStoreKeyValueStore(session: session)).map(\.text), ["Unmistakable-Note"])
    }

    // MARK: - The list

    func testNotesComeBackNewestFirstAndDeleteOneByOne() throws {
        _ = try NotesStore.add("first", in: keyValue)
        let two = try NotesStore.add("second", in: keyValue)
        XCTAssertEqual(two.map(\.text), ["second", "first"])
        XCTAssertEqual(try NotesStore.all(in: keyValue), two)

        let one = try NotesStore.delete([two[0].id], in: keyValue)

        XCTAssertEqual(one.map(\.text), ["first"])
        XCTAssertEqual(try NotesStore.all(in: keyValue), one)
    }

    /// Nothing is written over a list that could not be read. The cost of getting this wrong is
    /// every note the person has.
    func testAFailedReadWritesNothing() throws {
        let store = RefusingKeyValue(refusesGet: true)

        XCTAssertThrowsError(try NotesStore.add("new", in: store))
        XCTAssertThrowsError(try NotesStore.delete([UUID()], in: store))

        XCTAssertEqual(store.puts, 0)
    }

    func testBytesThatDoNotDecodeReadAsNoList() throws {
        try keyValue.put(NotesStore.storageKey, Data("not json".utf8))

        XCTAssertEqual(try NotesStore.all(in: keyValue), [])
    }

    // MARK: - Out of UserDefaults

    /// What is on every device today: the list keeps its text, order and dates, and the plain copy
    /// is gone.
    func testAPlainListMovesIntoTheStoreWhole() throws {
        let plain = try plainList(["newest", "oldest"])
        defaults.set(plain, forKey: NotesStore.storageKey)

        try NotesStore.moveOutOfDefaults(into: keyValue, defaults: defaults, hasAccount: { true })

        XCTAssertEqual(try keyValue.get(NotesStore.storageKey), plain)
        XCTAssertEqual(try NotesStore.all(in: keyValue).map(\.text), ["newest", "oldest"])
        XCTAssertNil(defaults.object(forKey: NotesStore.storageKey))
    }

    /// A crash between the two writes of a move leaves both. The store's list wins, and the plain
    /// copy still goes.
    func testAListAlreadyInTheStoreIsNotOverwritten() throws {
        _ = try NotesStore.add("written after the move", in: keyValue)
        defaults.set(try plainList(["left behind"]), forKey: NotesStore.storageKey)

        try NotesStore.moveOutOfDefaults(into: keyValue, defaults: defaults, hasAccount: { true })

        XCTAssertEqual(try NotesStore.all(in: keyValue).map(\.text), ["written after the move"])
        XCTAssertNil(defaults.object(forKey: NotesStore.storageKey))
    }

    /// The store would not take it: the only copy stays where it is for the next launch.
    func testARefusedMoveKeepsThePlainCopy() throws {
        let plain = try plainList(["only copy"])
        defaults.set(plain, forKey: NotesStore.storageKey)

        XCTAssertThrowsError(try NotesStore.moveOutOfDefaults(into: RefusingKeyValue(refusesPut: true), defaults: defaults, hasAccount: { true }))

        XCTAssertEqual(defaults.data(forKey: NotesStore.storageKey), plain)
    }

    /// An install not yet on the store: `keyValue` is these same defaults, and this list is the
    /// only copy.
    func testAnInstallNotYetOnTheStoreKeepsItsList() throws {
        let plain = try plainList(["only copy"])
        defaults.set(plain, forKey: NotesStore.storageKey)

        try NotesStore.moveOutOfDefaults(into: DefaultsKeyValueStore(defaults: defaults), defaults: defaults, hasAccount: { true })

        XCTAssertEqual(defaults.data(forKey: NotesStore.storageKey), plain)
    }

    /// Seen on the stand: a wipe on an older build left a note, and the next account was shown it.
    /// With no account the list belongs to nobody and goes.
    func testWithNoAccountAPlainListGoesAndDoesNotMove() throws {
        defaults.set(try plainList(["the previous owner's note"]), forKey: NotesStore.storageKey)

        try NotesStore.moveOutOfDefaults(into: keyValue, defaults: defaults, hasAccount: { false })

        XCTAssertNil(defaults.object(forKey: NotesStore.storageKey))
        XCTAssertEqual(try NotesStore.all(in: keyValue), [])
    }

    /// A locked device answers "no account" and cannot open the store. The store's refusal has to
    /// come first, or a background launch before the first unlock deletes every note.
    func testALockedDeviceDeletesNothing() throws {
        let plain = try plainList(["only copy"])
        defaults.set(plain, forKey: NotesStore.storageKey)

        XCTAssertThrowsError(
            try NotesStore.moveOutOfDefaults(into: RefusingKeyValue(refusesGet: true), defaults: defaults, hasAccount: { false })
        )

        XCTAssertEqual(defaults.data(forKey: NotesStore.storageKey), plain)
    }

    func testNothingToMoveWritesNothing() throws {
        let store = RefusingKeyValue()

        try NotesStore.moveOutOfDefaults(into: store, defaults: defaults, hasAccount: { true })

        XCTAssertEqual(store.puts, 0)
    }

    // MARK: - The wipe

    /// The defect as it stood: a device that wipes before this list ever moved. Mutation: take the
    /// key out of `AccountWipeKeys.wiped` — this reddens.
    func testAWipeRemovesAPlainListThatNeverMoved() throws {
        defaults.set(try plainList(["the previous owner's note"]), forKey: NotesStore.storageKey)

        AccountWipeKeys.wipe(defaults)

        XCTAssertNil(defaults.object(forKey: NotesStore.storageKey))
    }

    /// Notes in the store go with the store's files.
    func testAWipedStoreHoldsNoNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("construct.db").path
        let key = SymmetricKey(size: .bits256)
        let session = try LocalStoreSession.open(at: URL(fileURLWithPath: path), key: key).get()
        _ = try NotesStore.add("gone", in: LocalStoreKeyValueStore(session: session))

        try session.wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let next = try LocalStoreSession.open(at: URL(fileURLWithPath: path), key: key).get()
        XCTAssertEqual(try NotesStore.all(in: LocalStoreKeyValueStore(session: next)), [])
    }
}

/// A store that says no where it is told to, and counts what it was asked to write.
private final class RefusingKeyValue: KeyValueStore, @unchecked Sendable {
    private struct Refused: Error {}
    private let refusesGet: Bool
    private let refusesPut: Bool
    private(set) var puts = 0

    init(refusesGet: Bool = false, refusesPut: Bool = false) {
        self.refusesGet = refusesGet
        self.refusesPut = refusesPut
    }

    func put(_ key: String, _ value: Data) throws {
        puts += 1
        if refusesPut { throw Refused() }
    }

    func get(_ key: String) throws -> Data? {
        if refusesGet { throw Refused() }
        return nil
    }

    func remove(_ key: String) throws {}

    func entries(withPrefix prefix: String) throws -> [(key: String, value: Data)] { [] }
}
