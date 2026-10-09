//
//  ChatsLive.swift
//  Construct Messenger
//
//  What the chats lists read, in place of `@FetchRequest<Chat>` and `@ObservedObject Chat`
//  (LOCAL_STORE_MIGRATION_PLAN step 2, chats C). The list is read through `ChatStore` the first
//  time a screen asks and kept; a save that touches a chat drops it, and the revision every reader
//  depends on moves, so SwiftUI draws again. Rows are values, so a row redraws when its value
//  differs — the `.id(...)` the rows carried to force a redraw of a managed object is gone.
//

import Foundation
import Observation
import CoreData

@MainActor
@Observable
final class ChatsLive {

    #if DEBUG
    static private(set) var shared = ChatsLive(store: LocalRepositories.chats)

    /// A preview's own container: previews seed rows there, not in the app's store.
    static func useForPreview(_ container: NSPersistentContainer) {
        shared = ChatsLive(store: CoreDataChatStore(container: container))
    }
    #else
    static let shared = ChatsLive(store: LocalRepositories.chats)
    #endif

    /// Moves on every change a reader could see.
    private(set) var revision = 0

    /// The list, once a screen has asked for it. Not observed: filled while a view draws, which
    /// must not itself be a change.
    @ObservationIgnored private var list: [ChatRecord]?
    @ObservationIgnored private let store: any ChatStore
    @ObservationIgnored nonisolated(unsafe) private var listening: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var replaced: NSObjectProtocol?

    init(store: any ChatStore) {
        self.store = store
        let changes = store.changes()
        listening = Task { [weak self] in
            for await _ in changes { self?.refresh() }
        }
        replaced = NotificationCenter.default.addObserver(
            forName: .localStoreReplaced, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        listening?.cancel()
        if let replaced { NotificationCenter.default.removeObserver(replaced) }
    }

    /// Every chat, pinned first, then most recent, chats with no message last — the crate's order.
    func chats() -> [ChatRecord] {
        _ = revision
        if let list { return list }
        let rows = (try? store.chats()) ?? []
        list = rows
        return rows
    }

    func chat(_ id: String) -> ChatRecord? {
        chats().first { $0.id == id }
    }

    /// The badge on the chats tab.
    var totalUnread: Int {
        chats().reduce(0) { $0 + $1.unreadCount }
    }

    /// Whether `chat` answers a search: the name shown for its person, their username, or the
    /// preview. Shared by the iOS and the Desktop lists, which each kept a copy.
    static func matches(_ chat: ChatRecord, query: String) -> Bool {
        let contact = ContactsLive.shared.contact(chat.peerId)
        return (contact?.resolvedDisplayName ?? "").localizedCaseInsensitiveContains(query)
            || (contact?.username ?? "").localizedCaseInsensitiveContains(query)
            || (chat.lastMessageText ?? "").localizedCaseInsensitiveContains(query)
    }

    private func refresh() {
        list = nil
        revision += 1
    }
}
