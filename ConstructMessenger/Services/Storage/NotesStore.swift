//
//  NotesStore.swift
//  Construct Messenger
//
//  Settings → Drafts: notes kept on this device only (`decisions/notes-stay-on-the-device.md`). They
//  live in the encrypted store's `kv` and go when the store goes. Until 2026-11-07 they were JSON in
//  `UserDefaults`, a plain file, under a key no wipe knew (todo/278).
//

import Foundation

struct NoteItem: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
}

enum NotesStore {
    /// The same key and the same bytes as in `UserDefaults`: moving a list needs no conversion, and
    /// an install not yet on the store reads what it always did.
    static let storageKey = "local_drafts"

    /// Newest first. A read that fails throws, so nothing is written over a list that could not be
    /// read. Bytes that do not decode hold no list anybody could read, and read as none.
    static func all(in keyValue: any KeyValueStore = LocalRepositories.keyValue) throws -> [NoteItem] {
        guard let data = try keyValue.get(storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([NoteItem].self, from: data)
        } catch {
            Log.error("NotesStore: the stored list does not decode — \(error)", category: "Storage")
            return []
        }
    }

    /// The list with `text` on top, once it is stored.
    static func add(
        _ text: String, now: Date = Date(), in keyValue: any KeyValueStore = LocalRepositories.keyValue
    ) throws -> [NoteItem] {
        let notes = [NoteItem(id: UUID(), text: text, createdAt: now)] + (try all(in: keyValue))
        try keyValue.put(storageKey, try JSONEncoder().encode(notes))
        return notes
    }

    /// The list without `ids`, once it is stored.
    static func delete(
        _ ids: Set<UUID>, in keyValue: any KeyValueStore = LocalRepositories.keyValue
    ) throws -> [NoteItem] {
        let notes = try all(in: keyValue).filter { !ids.contains($0.id) }
        try keyValue.put(storageKey, try JSONEncoder().encode(notes))
        return notes
    }

    /// Takes the list out of `UserDefaults` and into the store. The plain copy goes only once the
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
}
