//
//  NotesModel.swift
//  Construct Messenger
//
//  The notes list (todo 279): pages, search, and the writes the screen makes. Follows the store's
//  changes, so a note saved from a chat is there when the screen is.
//

import Foundation
import Observation

@Observable
@MainActor
final class NotesModel {
    /// What is shown: the list, or what the search found.
    private(set) var notes: [Note] = []
    /// No page left.
    private(set) var isComplete = false
    var query = "" {
        didSet { if query != oldValue { reload() } }
    }

    @ObservationIgnored private let store: any NotesStore
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let deleteFiles: @MainActor ([String]) -> Void

    init(
        store: any NotesStore = LocalRepositories.notes,
        pageSize: Int = 60,
        deleteFiles: @escaping @MainActor ([String]) -> Void = { MediaManager.shared.deleteFiles($0) }
    ) {
        self.store = store
        self.pageSize = max(1, pageSize)
        self.deleteFiles = deleteFiles
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Reads again for as long as the screen is up: at once, and after each write.
    func follow() async {
        let changes = store.changes()
        reload()
        for await _ in changes { reload() }
    }

    /// As many as were held, so a change does not throw the reader back to the first page.
    func reload() {
        do {
            if isSearching {
                notes = try store.search(trimmedQuery, limit: 200)
                isComplete = true
            } else {
                let limit = max(pageSize, notes.count)
                notes = try store.notes(after: nil, limit: limit)
                isComplete = notes.count < limit
            }
        } catch {
            Log.error("Notes: not read — \(error)", category: "Notes")
            isComplete = true
        }
    }

    /// Called as `note` appears: the next page once the last one is shown.
    func loadMoreIfNeeded(after note: Note) {
        guard !isComplete, !isSearching, note.id == notes.last?.id else { return }
        do {
            let page = try store.notes(after: note, limit: pageSize)
            notes.append(contentsOf: page)
            isComplete = page.count < pageSize
        } catch {
            Log.error("Notes: a page did not load — \(error)", category: "Notes")
            isComplete = true
        }
    }

    /// True once stored; what was typed stays in the editor otherwise.
    func add(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return written("add") { try store.insert(Note(text: text)) }
    }

    /// Only a text note is edited: the words of one that holds media are its caption, part of it.
    func edit(_ note: Note, text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, note.plainText != nil else { return false }
        if text == note.plainText { return true }
        return written("edit") {
            guard let released = try store.edit(note.id, body: LocalMessagePayload.encodeText(text), editedAt: Date()) else { return false }
            MessageDisplayCache.shared.evict(messageId: NoteRow.rowId(note.id))
            deleteFiles(released)
            return true
        }
    }

    func togglePin(_ note: Note) {
        _ = written("pin") { try store.setPinned(note.id, !note.isPinned) }
    }

    func delete(_ note: Note) {
        _ = written("delete") {
            deleteFiles(try store.delete([note.id]))
            MessageDisplayCache.shared.evict(messageId: NoteRow.rowId(note.id))
            return true
        }
    }

    func note(_ id: String) -> Note? { try? store.note(id) }

    private func written(_ what: String, _ write: () throws -> Bool) -> Bool {
        do {
            return try write()
        } catch {
            Log.error("Notes: \(what) failed — \(error)", category: "Notes")
            ErrorRouter.shared.report(.notice(message: UserText("notes_not_saved").resolved, actionTitle: nil))
            return false
        }
    }
}
