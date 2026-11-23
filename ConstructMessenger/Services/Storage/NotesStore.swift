//
//  NotesStore.swift
//  Construct Messenger
//
//  Settings → Notes: what a person keeps for themselves, on this device only
//  (`decisions/notes-stay-on-the-device.md`, todo 279). A note is not a message: no chat, no peer,
//  nothing sent. Its body is a message body (CTM1), so it is drawn by what draws a message; the
//  files it holds stay whatever the media cache's limit says (`MediaManager.heldByNotes`).
//

import Foundation

struct Note: Identifiable, Equatable, Sendable {
    let id: String
    /// CTM1 (`LocalMessagePayload`).
    var body: Data
    var createdAt: Date
    var editedAt: Date? = nil
    var isPinned = false
    /// Whose message it was saved from, as they were called then. Nil for one's own words.
    var sourceName: String? = nil
    /// When that message was sent.
    var sourceAt: Date? = nil

    init(
        id: String = UUID().uuidString.lowercased(), body: Data, createdAt: Date = Date(), editedAt: Date? = nil,
        isPinned: Bool = false, sourceName: String? = nil, sourceAt: Date? = nil
    ) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.isPinned = isPinned
        self.sourceName = sourceName
        self.sourceAt = sourceAt
    }

    /// A note of plain words.
    init(text: String, id: String = UUID().uuidString.lowercased(), createdAt: Date = Date()) {
        self.init(id: id, body: LocalMessagePayload.encodeText(text), createdAt: createdAt)
    }

    /// The words of a text note, which can be edited; nil for one that holds media or a sticker.
    var plainText: String? { LocalMessagePayload.decode(body).plainText }
    /// What it holds, as a send of it would carry it; nil for nothing to send.
    var content: ForwardItem? {
        let payload = LocalMessagePayload.decode(body)
        return ForwardItem.content(legacyBody: payload.displayString, plainText: payload.plainText, sticker: payload.stickerReference)
    }
    /// The words to show and find: the text, or a caption.
    var readableText: String { LocalMessagePayload.decode(body).readableText }
}

protocol NotesStore: Sendable {
    /// Pinned first, each part newest first; `after` is the last note of the previous page.
    func notes(after: Note?, limit: Int) throws -> [Note]
    /// In the list's order. Fewer than three characters find nothing.
    func search(_ query: String, limit: Int) throws -> [Note]
    func note(_ id: String) throws -> Note?
    /// The media ids of every file a note holds.
    func heldMediaIds() throws -> Set<String>
    /// The ids of notes written or deleted, once per write.
    func changes() -> AsyncStream<Set<String>>

    /// True when added; one already held is left as it is.
    @discardableResult func insert(_ note: Note) throws -> Bool
    /// What the note says now. The media ids neither a note nor a message holds any more; nil when
    /// there is no such note.
    @discardableResult func edit(_ id: String, body: Data, editedAt: Date) throws -> [String]?
    @discardableResult func setPinned(_ id: String, _ pinned: Bool) throws -> Bool
    /// The media ids neither a note nor a message holds any more: the copies to delete.
    @discardableResult func delete(_ ids: Set<String>) throws -> [String]
}

/// On the core's tables (construct-core 0.81.0).
final class LocalStoreNotesStore: NotesStore, @unchecked Sendable {
    private let session: LocalStoreSession

    init(session: LocalStoreSession) {
        self.session = session
    }

    func notes(after: Note?, limit: Int) throws -> [Note] {
        try session.store.notes(after: after?.local, limit: UInt32(clamping: limit)).map { Note($0) }
    }

    func search(_ query: String, limit: Int) throws -> [Note] {
        try session.store.searchNotes(query: query, limit: UInt32(clamping: limit)).map { Note($0) }
    }

    func note(_ id: String) throws -> Note? {
        try session.store.note(id: id).map { Note($0) }
    }

    func heldMediaIds() throws -> Set<String> {
        Set(try session.store.notesMedia().map(\.mediaId))
    }

    func changes() -> AsyncStream<Set<String>> { session.changes(of: .notes) }

    func insert(_ note: Note) throws -> Bool {
        try session.store.insertNote(note: note.local, searchText: Self.words(note.body), media: Self.media(note.body)) == .inserted
    }

    func edit(_ id: String, body: Data, editedAt: Date) throws -> [String]? {
        guard let released = try session.store.editNote(
            id: id, body: body, searchText: Self.words(body), media: Self.media(body), editedAt: editedAt.unixMs
        ) else { return nil }
        return try heldByNoMessage(released)
    }

    func setPinned(_ id: String, _ pinned: Bool) throws -> Bool {
        try session.store.setNotePinned(id: id, pinned: pinned)
    }

    func delete(_ ids: Set<String>) throws -> [String] {
        try heldByNoMessage(session.store.deleteNotes(ids: Array(ids)))
    }

    /// A chat's bubble may show the same file: it is the chat's then, under the cache's rules.
    private func heldByNoMessage(_ mediaIds: [String]) throws -> [String] {
        guard !mediaIds.isEmpty else { return [] }
        let held = Set(try session.store.mediaOwners(mediaIds: mediaIds).map(\.mediaId))
        return mediaIds.filter { !held.contains($0) }
    }

    private static func words(_ body: Data) -> String? {
        let text = LocalMessagePayload.decode(body).readableText
        return text.isEmpty ? nil : text
    }

    private static func media(_ body: Data) -> [LocalMediaEntry] {
        MessageMediaIndex.entries(for: body) ?? []
    }
}

/// Core Data, on an install whose data has not moved to the store: there is nowhere to keep a note
/// yet. The list an older build kept stays where it is until the move (`LegacyNotes`).
struct NoNotesStore: NotesStore {
    struct Unavailable: Error {}

    func notes(after: Note?, limit: Int) throws -> [Note] { [] }
    func search(_ query: String, limit: Int) throws -> [Note] { [] }
    func note(_ id: String) throws -> Note? { nil }
    func heldMediaIds() throws -> Set<String> { [] }
    func changes() -> AsyncStream<Set<String>> { AsyncStream { $0.finish() } }
    func insert(_ note: Note) throws -> Bool { throw Unavailable() }
    func edit(_ id: String, body: Data, editedAt: Date) throws -> [String]? { throw Unavailable() }
    func setPinned(_ id: String, _ pinned: Bool) throws -> Bool { throw Unavailable() }
    func delete(_ ids: Set<String>) throws -> [String] { throw Unavailable() }
}

private extension Note {
    init(_ row: LocalNote) {
        self.init(
            id: row.id, body: row.body, createdAt: Date(unixMs: row.createdAt), editedAt: row.editedAt.map { Date(unixMs: $0) },
            isPinned: row.isPinned, sourceName: row.sourceName, sourceAt: row.sourceAt.map { Date(unixMs: $0) }
        )
    }

    var local: LocalNote {
        LocalNote(
            id: id, body: body, createdAt: createdAt.unixMs, editedAt: editedAt?.unixMs, isPinned: isPinned,
            sourceName: sourceName, sourceAt: sourceAt?.unixMs
        )
    }
}

// MARK: - The list before 0.81

/// Notes were one JSON list of texts: in `UserDefaults` until 2026-11-07 (todo 278), in the store's
/// `kv` after. Read once, into the notes table. Remove after `lastDay`; `LegacyNotesTests` fails then.
enum LegacyNotes {
    static let lastDay = "2027-03-01"
    /// The key the list has had in both places.
    static let storageKey = "local_drafts"

    struct Item: Codable, Equatable {
        let id: UUID
        let text: String
        let createdAt: Date
    }

    /// Takes the list out of `UserDefaults` and into `kv`. The plain copy goes only once the
    /// store holds a list; if the store refuses, it stays and the next launch tries again. A list
    /// already in the store is the newer one: nothing writes to `UserDefaults` after this has run.
    ///
    /// With no account on the device the list is what a wipe on an older build left behind, and it
    /// goes rather than moves: moved, the next account would be shown the last one's notes. The
    /// store is read first because a locked device answers "no account" too: the account id and the
    /// store key share one Keychain accessibility, so a read that succeeds means the answer is real.
    ///
    /// An install not yet on the store has `UserDefaults` for its `keyValue`: the list is already
    /// where it would be moved to, and "take the plain copy away" would delete the only one.
    static func moveOutOfDefaults(
        into keyValue: any KeyValueStore = LocalRepositories.keyValue,
        defaults: UserDefaults = .standard,
        hasAccount: () -> Bool = { KeychainManager.shared.loadUserID() != nil }
    ) throws {
        guard !(keyValue is DefaultsKeyValueStore),
              let plain = defaults.data(forKey: storageKey) else { return }
        let held = try keyValue.get(storageKey)
        if held == nil, hasAccount() {
            try keyValue.put(storageKey, plain)
        }
        defaults.removeObject(forKey: storageKey)
    }

    /// The list in `kv` becomes notes, each under the id it had, and goes once all of them are in.
    /// Run again after a failure it adds nothing twice. Bytes that do not decode are left: they hold
    /// no list anybody could read, and deleting them is not this function's to decide.
    static func moveIntoNotes(
        from keyValue: any KeyValueStore = LocalRepositories.keyValue,
        into notes: any NotesStore = LocalRepositories.notes
    ) throws {
        guard !(notes is NoNotesStore), let data = try keyValue.get(storageKey) else { return }
        let items: [Item]
        do {
            items = try JSONDecoder().decode([Item].self, from: data)
        } catch {
            Log.error("LegacyNotes: the stored list does not decode — \(error)", category: "Storage")
            return
        }
        for item in items {
            try notes.insert(Note(text: item.text, id: item.id.uuidString.lowercased(), createdAt: item.createdAt))
        }
        try keyValue.remove(storageKey)
        Log.info("LegacyNotes: \(items.count) note(s) moved into the store", category: "Storage")
    }
}
