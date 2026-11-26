//
//  NotesLatest.swift
//  Construct Messenger
//
//  The newest note, for the Notes row of the chat list. Notes stand among the chats as one row,
//  placed by the time of the newest note as a chat is placed by its last message (owner,
//  2026-11-26: as people know it from other messengers; a Notes tab and before it a Settings row
//  were the places tried first). Read once and kept; a change to the notes drops it, and the
//  revision every reader depends on moves.
//

import Foundation
import Observation

@MainActor
@Observable
final class NotesLatest {
    static let shared = NotesLatest { LocalRepositories.notes }

    /// Moves on every change a reader could see.
    private(set) var revision = 0

    /// Not observed: filled while a view draws, which must not itself be a change. `.some(nil)`
    /// is "read, and there is no note".
    @ObservationIgnored private var cached: Note??
    /// Asked on every read: a sign-out replaces the app's store under a running app.
    @ObservationIgnored private let currentStore: () -> any NotesStore
    @ObservationIgnored nonisolated(unsafe) private var listening: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var replaced: NSObjectProtocol?

    init(store: @escaping () -> any NotesStore) {
        currentStore = store
        listen()
        replaced = NotificationCenter.default.addObserver(
            forName: .localStoreReplaced, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.listen()
                self?.refresh()
            }
        }
    }

    deinit {
        listening?.cancel()
        if let replaced { NotificationCenter.default.removeObserver(replaced) }
    }

    /// The newest note, or nil when there is none.
    func latest() -> Note? {
        _ = revision
        if let cached { return cached }
        let note = (try? Self.latest(in: currentStore())) ?? nil
        cached = .some(note)
        return note
    }

    /// The note written last. The store lists pinned notes first and each part newest first, so
    /// the newest is the first unpinned note or one of the pinned before it; a page or two is read,
    /// never the whole list.
    nonisolated static func latest(in store: any NotesStore, page: Int = 20) throws -> Note? {
        var newest: Note?
        var after: Note?
        while true {
            let notes = try store.notes(after: after, limit: page)
            for note in notes {
                if newest.map({ note.createdAt > $0.createdAt }) ?? true { newest = note }
                if !note.isPinned { return newest }
            }
            guard notes.count == page, let last = notes.last else { return newest }
            after = last
        }
    }

    private func listen() {
        listening?.cancel()
        let changes = currentStore().changes()
        listening = Task { [weak self] in
            for await _ in changes { self?.refresh() }
        }
    }

    private func refresh() {
        cached = nil
        revision += 1
    }
}

/// One row of the chat list: a chat, or the Notes row.
enum ChatsListEntry: Identifiable, Equatable {
    case chat(ChatRecord)
    case notes(Note?)

    /// The Notes row's id where a chat id goes — the list's navigation and selection.
    static let notesId = "konstruct.notes"

    var id: String {
        switch self {
        case .chat(let chat): return chat.id
        case .notes: return Self.notesId
        }
    }

    /// The list with the Notes row in it: after the pinned chats, then by the time of the newest
    /// note among the chats' last messages; with no note, at the end. `chats` come in the store's
    /// order — pinned first, then most recent, chats with no message last.
    static func merged(_ chats: [ChatRecord], newestNote: Note?) -> [ChatsListEntry] {
        var entries = chats.map(ChatsListEntry.chat)
        let at: Int
        if let noteTime = newestNote?.createdAt {
            at = chats.firstIndex { chat in
                !chat.isPinned && (chat.lastMessageTime.map { $0 < noteTime } ?? true)
            } ?? chats.count
        } else {
            at = chats.count
        }
        entries.insert(.notes(newestNote), at: at)
        return entries
    }
}
