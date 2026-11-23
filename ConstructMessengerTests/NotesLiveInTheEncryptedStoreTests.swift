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
        try JSONEncoder().encode(texts.map { LegacyNotes.Item(id: UUID(), text: $0, createdAt: Date(timeIntervalSince1970: 1_700_000_000)) })
    }

    // MARK: - On disk

    /// The promise itself: neither the words nor the search index of them. Mutation: keep the list
    /// in `UserDefaults` — this reddens.
    func testANoteIsNotReadableInTheStoreFileOrInDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("construct.db").path
        let session = try LocalStoreSession.open(at: URL(fileURLWithPath: path), key: SymmetricKey(size: .bits256)).get()

        let notes = LocalStoreNotesStore(session: session)
        try notes.insert(Note(text: "Unmistakable-Note"))

        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        if let wal = try? Data(contentsOf: URL(fileURLWithPath: path + "-wal")) { bytes.append(wal) }
        XCTAssertNil(bytes.range(of: Data("Unmistakable".utf8)))
        XCTAssertEqual(try notes.notes(after: nil, limit: 5).map(\.plainText), ["Unmistakable-Note"])
    }

    // MARK: - Out of the list in kv

    private var notes: LocalStoreNotesStore { LocalStoreNotesStore(session: session) }

    /// Text, date, order and id, and the list is gone. Again, nothing is added twice — a crash
    /// between the last note and the list's end. Mutations: a fresh id; keep the list.
    func testTheListBecomesNotesOnce() throws {
        let list = try plainList(["newest", "oldest"])
        try keyValue.put(LegacyNotes.storageKey, list)

        try LegacyNotes.moveIntoNotes(from: keyValue, into: notes)

        XCTAssertNil(try keyValue.get(LegacyNotes.storageKey))
        let moved = try notes.notes(after: nil, limit: 5)
        XCTAssertEqual(Set(moved.map(\.plainText)), ["newest", "oldest"])
        XCTAssertEqual(Set(moved.map(\.createdAt)), [Date(timeIntervalSince1970: 1_700_000_000)])

        try keyValue.put(LegacyNotes.storageKey, list)
        try LegacyNotes.moveIntoNotes(from: keyValue, into: notes)
        XCTAssertEqual(try notes.notes(after: nil, limit: 5), moved)
    }

    /// The list goes only once every note is in. Mutation: remove it first.
    func testTheListStaysWhenANoteIsRefused() throws {
        struct Refusing: NotesStore {
            let inner: LocalStoreNotesStore
            func notes(after: Note?, limit: Int) throws -> [Note] { [] }
            func search(_ query: String, limit: Int) throws -> [Note] { [] }
            func note(_ id: String) throws -> Note? { nil }
            func heldMediaIds() throws -> Set<String> { [] }
            func changes() -> AsyncStream<Set<String>> { AsyncStream { $0.finish() } }
            func insert(_ note: Note) throws -> Bool { throw NoNotesStore.Unavailable() }
            func edit(_ id: String, body: Data, editedAt: Date) throws -> [String]? { nil }
            func setPinned(_ id: String, _ pinned: Bool) throws -> Bool { false }
            func delete(_ ids: Set<String>) throws -> [String] { [] }
        }
        try keyValue.put(LegacyNotes.storageKey, try plainList(["only copy"]))
        XCTAssertThrowsError(try LegacyNotes.moveIntoNotes(from: keyValue, into: Refusing(inner: notes)))
        XCTAssertNotNil(try keyValue.get(LegacyNotes.storageKey))
    }

    /// An install not yet on the store has nowhere to move them to: the list stays.
    func testWithNoNotesStoreTheListStays() throws {
        try keyValue.put(LegacyNotes.storageKey, try plainList(["only copy"]))
        try LegacyNotes.moveIntoNotes(from: keyValue, into: NoNotesStore())
        XCTAssertNotNil(try keyValue.get(LegacyNotes.storageKey))
    }

    func testBytesThatDoNotDecodeAreLeft() throws {
        try keyValue.put(LegacyNotes.storageKey, Data("not json".utf8))
        try LegacyNotes.moveIntoNotes(from: keyValue, into: notes)
        XCTAssertEqual(try keyValue.get(LegacyNotes.storageKey), Data("not json".utf8))
        XCTAssertEqual(try notes.notes(after: nil, limit: 5), [])
    }

    /// Remove `LegacyNotes`, its tests and the lines in `ConstructMessengerApp` after this day.
    func testTheMoveIsNotPastItsLastDay() throws {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        format.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertLessThanOrEqual(Date(), try XCTUnwrap(format.date(from: LegacyNotes.lastDay)))
    }

    // MARK: - Out of UserDefaults

    /// What is on every device today: the list keeps its text, order and dates, and the plain copy
    /// is gone.
    func testAPlainListMovesIntoTheStoreWhole() throws {
        let plain = try plainList(["newest", "oldest"])
        defaults.set(plain, forKey: LegacyNotes.storageKey)

        try LegacyNotes.moveOutOfDefaults(into: keyValue, defaults: defaults, hasAccount: { true })

        XCTAssertEqual(try keyValue.get(LegacyNotes.storageKey), plain)
        XCTAssertNil(defaults.object(forKey: LegacyNotes.storageKey))
    }

    /// A crash between the two writes of a move leaves both. The store's list wins, and the plain
    /// copy still goes.
    func testAListAlreadyInTheStoreIsNotOverwritten() throws {
        let newer = try plainList(["written after the move"])
        try keyValue.put(LegacyNotes.storageKey, newer)
        defaults.set(try plainList(["left behind"]), forKey: LegacyNotes.storageKey)

        try LegacyNotes.moveOutOfDefaults(into: keyValue, defaults: defaults, hasAccount: { true })

        XCTAssertEqual(try keyValue.get(LegacyNotes.storageKey), newer)
        XCTAssertNil(defaults.object(forKey: LegacyNotes.storageKey))
    }

    /// The store would not take it: the only copy stays where it is for the next launch.
    func testARefusedMoveKeepsThePlainCopy() throws {
        let plain = try plainList(["only copy"])
        defaults.set(plain, forKey: LegacyNotes.storageKey)

        XCTAssertThrowsError(try LegacyNotes.moveOutOfDefaults(into: RefusingKeyValue(refusesPut: true), defaults: defaults, hasAccount: { true }))

        XCTAssertEqual(defaults.data(forKey: LegacyNotes.storageKey), plain)
    }

    /// An install not yet on the store: `keyValue` is these same defaults, and this list is the
    /// only copy.
    func testAnInstallNotYetOnTheStoreKeepsItsList() throws {
        let plain = try plainList(["only copy"])
        defaults.set(plain, forKey: LegacyNotes.storageKey)

        try LegacyNotes.moveOutOfDefaults(into: DefaultsKeyValueStore(defaults: defaults), defaults: defaults, hasAccount: { true })

        XCTAssertEqual(defaults.data(forKey: LegacyNotes.storageKey), plain)
    }

    /// Seen on the stand: a wipe on an older build left a note, and the next account was shown it.
    /// With no account the list belongs to nobody and goes.
    func testWithNoAccountAPlainListGoesAndDoesNotMove() throws {
        defaults.set(try plainList(["the previous owner's note"]), forKey: LegacyNotes.storageKey)

        try LegacyNotes.moveOutOfDefaults(into: keyValue, defaults: defaults, hasAccount: { false })

        XCTAssertNil(defaults.object(forKey: LegacyNotes.storageKey))
        XCTAssertNil(try keyValue.get(LegacyNotes.storageKey))
    }

    /// A locked device answers "no account" and cannot open the store. The store's refusal has to
    /// come first, or a background launch before the first unlock deletes every note.
    func testALockedDeviceDeletesNothing() throws {
        let plain = try plainList(["only copy"])
        defaults.set(plain, forKey: LegacyNotes.storageKey)

        XCTAssertThrowsError(
            try LegacyNotes.moveOutOfDefaults(into: RefusingKeyValue(refusesGet: true), defaults: defaults, hasAccount: { false })
        )

        XCTAssertEqual(defaults.data(forKey: LegacyNotes.storageKey), plain)
    }

    func testNothingToMoveWritesNothing() throws {
        let store = RefusingKeyValue()

        try LegacyNotes.moveOutOfDefaults(into: store, defaults: defaults, hasAccount: { true })

        XCTAssertEqual(store.puts, 0)
    }

    // MARK: - The wipe

    /// The defect as it stood: a device that wipes before this list ever moved. Mutation: take the
    /// key out of `AccountWipeKeys.wiped` — this reddens.
    func testAWipeRemovesAPlainListThatNeverMoved() throws {
        defaults.set(try plainList(["the previous owner's note"]), forKey: LegacyNotes.storageKey)

        AccountWipeKeys.wipe(defaults)

        XCTAssertNil(defaults.object(forKey: LegacyNotes.storageKey))
    }

    /// Notes in the store go with the store's files.
    func testAWipedStoreHoldsNoNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("construct.db").path
        let key = SymmetricKey(size: .bits256)
        let session = try LocalStoreSession.open(at: URL(fileURLWithPath: path), key: key).get()
        try LocalStoreNotesStore(session: session).insert(Note(text: "gone"))

        try session.wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let next = try LocalStoreSession.open(at: URL(fileURLWithPath: path), key: key).get()
        XCTAssertEqual(try LocalStoreNotesStore(session: next).notes(after: nil, limit: 5), [])
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
