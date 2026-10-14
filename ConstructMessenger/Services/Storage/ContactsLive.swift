//
//  ContactsLive.swift
//  Construct Messenger
//
//  What the screens read a contact from, in place of `@FetchRequest<User>` and
//  `@ObservedObject User` (LOCAL_STORE_MIGRATION_PLAN step 2). A row is read through
//  `ContactStore` the first time a screen asks for it and kept; a save that touches it reads it
//  again, and the revision every reader depends on moves, so SwiftUI draws again. Contacts change
//  rarely, so one revision for all of them costs a redraw of what shows a contact, nothing more.
//

import Foundation
import Observation
import CoreData

@MainActor
@Observable
final class ContactsLive {

    #if DEBUG
    static private(set) var shared = ContactsLive(store: LocalRepositories.contacts)

    /// A preview's own container: previews seed rows there, not in the app's store.
    static func useForPreview(_ container: NSPersistentContainer) {
        shared = ContactsLive(store: CoreDataContactStore(container: container))
    }
    #else
    static let shared = ContactsLive(store: LocalRepositories.contacts)
    #endif

    /// Moves on every change a reader could see. Read by `contact(_:)`, which is how a view comes
    /// to depend on it.
    private(set) var revision = 0

    /// What has been read so far — `nil` when there is no row. Not observed: filled while a view
    /// draws, which must not itself be a change.
    @ObservationIgnored private var cache: [String: ContactRecord?] = [:]
    /// The contacts list, once a screen has asked for it.
    @ObservationIgnored private var list: [ContactRecord]?
    @ObservationIgnored private let store: any ContactStore
    @ObservationIgnored nonisolated(unsafe) private var listening: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var replaced: NSObjectProtocol?

    init(store: any ContactStore) {
        self.store = store
        let changes = store.changes()
        listening = Task { [weak self] in
            for await ids in changes { self?.refresh(ids) }
        }
        replaced = NotificationCenter.default.addObserver(
            forName: .localStoreReplaced, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetEverything() }
        }
    }

    deinit {
        listening?.cancel()
        if let replaced { NotificationCenter.default.removeObserver(replaced) }
    }

    /// The contact `id`, or nil when we hold no row for them.
    func contact(_ id: String) -> ContactRecord? {
        _ = revision
        if let held = cache[id] { return held }
        let row = try? store.contact(id)
        cache[id] = row
        return row
    }

    /// People marked as contacts, by the name shown for them in the reader's language
    /// (`localizedStandardCompare`), then id. The store's own collation cannot do this: SQLite's
    /// NOCASE folds ASCII only, so Cyrillic and Japanese would sort by code point.
    func contacts() -> [ContactRecord] {
        _ = revision
        if let list { return list }
        let rows = ((try? store.contacts()) ?? []).sorted(by: Self.shownOrder)
        list = rows
        return rows
    }

    nonisolated static func shownOrder(_ a: ContactRecord, _ b: ContactRecord) -> Bool {
        switch a.resolvedDisplayName.localizedStandardCompare(b.resolvedDisplayName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id < b.id
        }
    }

    private func refresh(_ ids: Set<String>) {
        let held = ids.filter { cache[$0] != nil }
        // Any change may add to the list, take from it or reorder it.
        let listHeld = list != nil
        guard !held.isEmpty || listHeld else { return }
        for id in held { cache[id] = try? store.contact(id) }
        list = nil
        revision += 1
    }

    /// The store under every row was replaced (sign-out, wipe): nothing held is true any more.
    private func forgetEverything() {
        cache.removeAll()
        list = nil
        revision += 1
    }
}
