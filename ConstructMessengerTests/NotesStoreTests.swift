//
//  NotesStoreTests.swift
//  Construct Messenger
//
//  Notes on the core's table (todo 279). Real store, real bodies.
//

import CryptoKit
import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

@MainActor
final class NotesStoreTests: XCTestCase {
    private var session: LocalStoreSession!
    private var notes: LocalStoreNotesStore!

    override func setUp() async throws {
        session = LocalStoreSession.inMemoryForTesting()
        notes = LocalStoreNotesStore(session: session)
        LocalRepositories.useLocalStoreForTesting(session)
        MessageDisplayCache.shared.evictAll()
    }

    override func tearDown() async throws {
        LocalRepositories.useLocalStoreForTesting(nil)
        MessageDisplayCache.shared.evictAll()
    }

    private func photo(_ mediaId: String, caption: String = "") -> Data {
        var item = Shared_Proto_Messaging_V1_MediaMessage()
        item.mediaID = mediaId
        item.encryptionKey = Data(repeating: 1, count: 32)
        item.mimeType = "image/jpeg"
        item.fileSize = 10
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = [item]
        album.caption = caption
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.mediaAlbum = album
        return LocalMessagePayload.encodeMessageContent(content)
    }

    // MARK: - The store

    /// Every field, at the millisecond. Mutation: drop one from either conversion.
    func testANoteComesBackWhole() throws {
        let at = Date(unixMs: 1_700_000_000_123)
        var note = Note(id: "n1", body: photo("m1"), createdAt: at, editedAt: Date(unixMs: 1_700_000_000_456),
                        isPinned: true, sourceName: "Bob", sourceAt: Date(unixMs: 1_600_000_000_789))
        XCTAssertTrue(try notes.insert(note))
        XCTAssertEqual(try notes.note("n1"), note)
        note.body = Data()
        XCTAssertFalse(try notes.insert(note), "one already held is left as it is")
        XCTAssertEqual(try notes.note("n1")?.body, photo("m1"))
    }

    /// A caption is found, the JSON a media body rehydrates to is not. Mutation: index
    /// `displayString`.
    func testWhatANoteSaysIsFoundAndWhatItIsMadeOfIsNot() throws {
        try notes.insert(Note(id: "p", body: photo("m1", caption: "beach sunset"), createdAt: Date(unixMs: 1)))
        try notes.insert(Note(text: "buy milk", id: "t", createdAt: Date(unixMs: 2)))
        XCTAssertEqual(try notes.search("sunset", limit: 10).map(\.id), ["p"])
        XCTAssertEqual(try notes.search("milk", limit: 10).map(\.id), ["t"])
        XCTAssertEqual(try notes.search("mediaId", limit: 10), [])
        XCTAssertEqual(try notes.search("image/jpeg", limit: 10), [])
    }

    /// The copies to delete are those neither a note nor a message holds. Mutations: name what a
    /// message still shows; name nothing.
    func testADeletedNoteLetsGoOfFilesNobodyHolds() throws {
        try notes.insert(Note(id: "n1", body: photo("only-the-note"), createdAt: Date(unixMs: 1)))
        try notes.insert(Note(id: "n2", body: photo("in-a-chat-too"), createdAt: Date(unixMs: 2)))
        XCTAssertEqual(try notes.heldMediaIds(), ["only-the-note", "in-a-chat-too"])
        let peer = UUID().uuidString.lowercased()
        try LocalRepositories.contacts.insert(.new(id: peer, isContact: true, addedAt: nil))
        let chat = try LocalRepositories.chats.openChat(withPeer: peer).chat
        var record = MessageRecord(note: Note(id: "x", body: photo("in-a-chat-too")))
        record = MessageRecord(
            id: UUID().uuidString.lowercased(), chatId: chat.id, fromUserId: peer, toUserId: "me", isSentByMe: false,
            timestamp: record.timestamp, orderKey: "1", body: record.body, contentType: .regular,
            deliveryStatus: .delivered, retryCount: 0, suiteId: 0, isEdited: false
        )
        try LocalRepositories.messages.insert(record, searchText: nil)

        XCTAssertEqual(try notes.delete(["n1", "n2"]), ["only-the-note"])
        XCTAssertEqual(try notes.heldMediaIds(), [])
    }

    func testAnEditChangesTheWordsAndNothingElse() throws {
        var note = Note(text: "buy milk", id: "n1", createdAt: Date(unixMs: 5))
        note.sourceName = "Bob"
        try notes.insert(note)
        XCTAssertEqual(try notes.edit("n1", body: LocalMessagePayload.encodeText("buy bread"), editedAt: Date(unixMs: 9)), [])
        let edited = try XCTUnwrap(try notes.note("n1"))
        XCTAssertEqual(edited.plainText, "buy bread")
        XCTAssertEqual(edited.editedAt, Date(unixMs: 9))
        XCTAssertEqual(edited.createdAt, Date(unixMs: 5))
        XCTAssertEqual(edited.sourceName, "Bob")
        XCTAssertNil(try notes.edit("gone", body: Data(), editedAt: Date()))
        XCTAssertEqual(try notes.search("milk", limit: 5), [])
    }

    /// Not yet on the store: a write is refused rather than lost.
    func testWithoutTheStoreAWriteIsRefused() {
        XCTAssertThrowsError(try NoNotesStore().insert(Note(text: "x")))
        XCTAssertEqual(try NoNotesStore().notes(after: nil, limit: 5), [])
    }

    // MARK: - Drawn as a row

    /// A note's body is read by its row id, and again after the cache is emptied — leaving the app
    /// empties it. Mutation: read every row id from the messages.
    func testANotesRowReadsItsBodyFromTheNotes() throws {
        let note = Note(id: "n1", body: photo("m1", caption: "beach"), createdAt: Date(unixMs: 1))
        try notes.insert(note)
        let row = TranscriptRow(note: note)
        MessageDisplayCache.shared.evictAll()
        XCTAssertEqual(row.readableText, "beach")
        XCTAssertNotNil(MessageBubbleContentParsing.parseMediaMessage(row.legacyBody))
        XCTAssertEqual(NoteRow.noteId(row.id), "n1")
        XCTAssertNil(NoteRow.noteId("n1"))
    }

    // MARK: - The list on the screen

    private func model(_ pageSize: Int = 2, deleted: @escaping @MainActor ([String]) -> Void = { _ in }) -> NotesModel {
        NotesModel(store: notes, pageSize: pageSize, deleteFiles: deleted)
    }

    /// Pages follow each other to the end, and a write keeps as many as were shown. Mutation:
    /// reload the first page only.
    func testPagesAndAWriteKeepTheReadersPlace() throws {
        for i in 1...5 { try notes.insert(Note(text: "note \(i)", id: "n\(i)", createdAt: Date(unixMs: Int64(i)))) }
        let model = model()
        model.reload()
        XCTAssertEqual(model.notes.map(\.id), ["n5", "n4"])
        model.loadMoreIfNeeded(after: model.notes[0])
        XCTAssertEqual(model.notes.count, 2, "only the last row asks for more")
        model.loadMoreIfNeeded(after: model.notes[1])
        XCTAssertEqual(model.notes.map(\.id), ["n5", "n4", "n3", "n2"])
        model.togglePin(model.notes[3])
        model.reload()
        XCTAssertEqual(model.notes.map(\.id), ["n2", "n5", "n4", "n3"])
        guard let last = model.notes.last else { return }
        model.loadMoreIfNeeded(after: last)
        XCTAssertEqual(model.notes.map(\.id), ["n2", "n5", "n4", "n3", "n1"])
        XCTAssertTrue(model.isComplete)
    }

    func testSearchingShowsWhatIsFoundAndClearingItTheList() throws {
        try notes.insert(Note(text: "buy milk", id: "a", createdAt: Date(unixMs: 1)))
        try notes.insert(Note(text: "call Bob", id: "b", createdAt: Date(unixMs: 2)))
        let model = model()
        model.query = "  milk "
        XCTAssertEqual(model.notes.map(\.id), ["a"])
        model.query = ""
        XCTAssertEqual(model.notes.map(\.id), ["b", "a"])
    }

    /// The words of a text note are edited; the caption of a saved photo is part of it and is not.
    /// Mutation: edit any note — the photo becomes a text.
    func testOnlyATextNoteIsEdited() throws {
        let text = Note(text: "buy milk", id: "t", createdAt: Date(unixMs: 1))
        let saved = Note(id: "p", body: photo("m1", caption: "beach"), createdAt: Date(unixMs: 2))
        try notes.insert(text)
        try notes.insert(saved)
        let model = model()
        XCTAssertTrue(model.edit(text, text: " buy bread "))
        XCTAssertEqual(try notes.note("t")?.plainText, "buy bread")
        XCTAssertFalse(model.edit(saved, text: "other"))
        XCTAssertFalse(model.edit(text, text: "  "))
        XCTAssertEqual(try notes.note("p")?.body, photo("m1", caption: "beach"))
        XCTAssertFalse(model.add("   "))
        XCTAssertTrue(model.add(" new "))
        XCTAssertEqual(try notes.search("new", limit: 5).first?.plainText, "new")
    }

    /// Deleting a note deletes the copies it let go. Mutation: keep them.
    func testDeletingANoteDeletesTheFilesItLetGo() throws {
        let saved = Note(id: "p", body: photo("m1"), createdAt: Date(unixMs: 1))
        try notes.insert(saved)
        var deleted: [String] = []
        model(deleted: { deleted += $0 }).delete(saved)
        XCTAssertEqual(deleted, ["m1"])
        XCTAssertNil(try notes.note("p"))
    }

    // MARK: - Saving a message

    private func receivedRow(_ body: Data, sentByMe: Bool = false) -> TranscriptRow {
        let record = MessageRecord(
            id: UUID().uuidString.lowercased(), chatId: "c", fromUserId: "bob", toUserId: "me", isSentByMe: sentByMe,
            timestamp: Date(unixMs: 1_600_000_000_000), orderKey: "1", body: body, contentType: .regular,
            deliveryStatus: .delivered, retryCount: 0, suiteId: 0, isEdited: false
        )
        MessageDisplayCache.shared.hold(record)
        return TranscriptRow(record, revision: 0)
    }

    /// The message's own bytes, whose it was and when, and its files fetched. Mutations: keep the
    /// text only; take one's own name; fetch nothing.
    func testASavedMessageKeepsWhatItHoldsAndWhoseItWas() async throws {
        let row = receivedRow(photo("m1", caption: "beach"))
        var fetched: [String] = []
        let outcome = try await NoteSaver.save(row, sourceName: "Bob", notes: notes, now: Date(unixMs: 7)) { fetched.append($0.mediaId) }
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(fetched, ["m1"])
        let saved = try XCTUnwrap(try notes.notes(after: nil, limit: 5).first)
        XCTAssertEqual(saved.body, photo("m1", caption: "beach"))
        XCTAssertEqual(saved.createdAt, Date(unixMs: 7))
        XCTAssertEqual(saved.sourceName, "Bob")
        XCTAssertEqual(saved.sourceAt, Date(unixMs: 1_600_000_000_000))

        _ = try await NoteSaver.save(receivedRow(LocalMessagePayload.encodeText("mine"), sentByMe: true), sourceName: "Bob", notes: notes) { _ in }
        XCTAssertNil(try notes.search("mine", limit: 5).first?.sourceName)
    }

    /// The network failing costs the file, not the note. Mutation: fetch before writing.
    func testAFileThatCannotBeFetchedCostsTheFileOnly() async throws {
        struct Offline: Error {}
        let row = receivedRow(photo("m1", caption: "beach"))
        let outcome = try await NoteSaver.save(row, sourceName: "Bob", notes: notes) { _ in throw Offline() }
        XCTAssertEqual(outcome, .savedWithoutFiles)
        XCTAssertEqual(try notes.notes(after: nil, limit: 5).count, 1)
    }

    // MARK: - The media a note holds is not cache

    /// Neither the limit, nor the age, nor "clear" takes a file a note holds, and it is counted
    /// apart. Mutations: drop any of the three checks; count it in the cache.
    func testNoLimitTakesAFileANoteHolds() throws {
        let kept = "note-held-\(UUID().uuidString)"
        let loose = "loose-\(UUID().uuidString)"
        try notes.insert(Note(id: "p", body: photo(kept), createdAt: Date()))
        let manager = MediaManager.shared
        let old = Date(timeIntervalSinceNow: -3 * 86_400)
        // The held one is the older: the limit would take it first.
        func write() throws {
            for (id, at) in [(kept, old.addingTimeInterval(-86_400)), (loose, old)] {
                manager.saveToDiskcache(Data(repeating: 1, count: 4_096), mediaId: id)
                try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: MediaManager.onDiskURL(for: id).path)
            }
        }
        let defaults = UserDefaults.standard
        let savedQuota = defaults.object(forKey: MediaManager.maxDiskCacheBytesKey)
        let savedDays = defaults.object(forKey: MediaManager.evictAfterDaysKey)
        defer {
            defaults.set(savedQuota, forKey: MediaManager.maxDiskCacheBytesKey)
            defaults.set(savedDays, forKey: MediaManager.evictAfterDaysKey)
            manager.deleteFiles([kept, loose])
        }

        try write()
        let usage = manager.diskUsage()
        XCTAssertGreaterThan(usage.notes, 4_000)
        XCTAssertGreaterThan(usage.cache, 4_000)
        XCTAssertEqual(manager.diskUsage(held: []).cache, usage.cache + usage.notes)

        defaults.set(1, forKey: MediaManager.maxDiskCacheBytesKey)
        manager.evictToQuota()
        XCTAssertTrue(MediaManager.hasOnDiskFile(mediaId: kept))
        XCTAssertFalse(MediaManager.hasOnDiskFile(mediaId: loose))

        defaults.set(0, forKey: MediaManager.maxDiskCacheBytesKey)
        try write()
        defaults.set(1, forKey: MediaManager.evictAfterDaysKey)
        manager.evictOldFiles()
        XCTAssertTrue(MediaManager.hasOnDiskFile(mediaId: kept))
        XCTAssertFalse(MediaManager.hasOnDiskFile(mediaId: loose))

        try write()
        manager.clearCache(includingDisk: true)
        XCTAssertTrue(MediaManager.hasOnDiskFile(mediaId: kept))
        XCTAssertFalse(MediaManager.hasOnDiskFile(mediaId: loose))

        manager.deleteFiles([kept])
        XCTAssertFalse(MediaManager.hasOnDiskFile(mediaId: kept))
    }

    /// The store not answering is not "no file is held". Mutation: treat it as none.
    func testWhenTheStoreDoesNotAnswerNothingIsKnownToBeLoose() {
        struct Broken: NotesStore {
            struct No: Error {}
            func notes(after: Note?, limit: Int) throws -> [Note] { throw No() }
            func search(_ query: String, limit: Int) throws -> [Note] { throw No() }
            func note(_ id: String) throws -> Note? { throw No() }
            func heldMediaIds() throws -> Set<String> { throw No() }
            func changes() -> AsyncStream<Set<String>> { AsyncStream { $0.finish() } }
            func insert(_ note: Note) throws -> Bool { throw No() }
            func edit(_ id: String, body: Data, editedAt: Date) throws -> [String]? { throw No() }
            func setPinned(_ id: String, _ pinned: Bool) throws -> Bool { throw No() }
            func delete(_ ids: Set<String>) throws -> [String] { throw No() }
        }
        XCTAssertNil(MediaManager.heldByNotes(Broken()))
        XCTAssertEqual(MediaManager.heldByNotes(notes), [])
    }
}
