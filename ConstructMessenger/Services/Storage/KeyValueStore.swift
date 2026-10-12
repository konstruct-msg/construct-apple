//
//  KeyValueStore.swift
//  Construct Messenger
//
//  Small app state with no table of its own, behind the storage seam with the operations
//  `LocalStore` has — `put`, `get`, `remove`, `entries_with_prefix` (construct-core 0.40.0, `kv`).
//  On iOS it is `UserDefaults`, where these values have always been; on macOS the crate's table,
//  which is encrypted with the rest of the store — `UserDefaults` there is a plain file, and some of
//  what lives here is who one writes to.
//
//  Only what nothing else on the platform needs to read belongs here: not settings (a Settings
//  screen and `@AppStorage` read `UserDefaults`), not what the notification extension reads.
//

import Foundation

protocol KeyValueStore: Sendable {
    func put(_ key: String, _ value: Data) throws
    func get(_ key: String) throws -> Data?
    func remove(_ key: String) throws
    /// Every entry whose key starts with `prefix`, by key.
    func entries(withPrefix prefix: String) throws -> [(key: String, value: Data)]
}

/// `UserDefaults`, as these values were kept before the seam.
final class DefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func put(_ key: String, _ value: Data) throws {
        defaults.set(value, forKey: key)
    }

    func get(_ key: String) throws -> Data? {
        defaults.data(forKey: key)
    }

    func remove(_ key: String) throws {
        defaults.removeObject(forKey: key)
    }

    func entries(withPrefix prefix: String) throws -> [(key: String, value: Data)] {
        defaults.dictionaryRepresentation()
            .compactMap { key, value in
                guard key.hasPrefix(prefix), let data = value as? Data else { return nil }
                return (key: key, value: data)
            }
            .sorted { $0.key < $1.key }
    }
}

/// The crate's `kv`, encrypted with the rest of the store. Off until step 4.
final class LocalStoreKeyValueStore: KeyValueStore, @unchecked Sendable {

    private let store: LocalStore

    init(session: LocalStoreSession) {
        self.store = session.store
    }

    func put(_ key: String, _ value: Data) throws {
        try store.put(key: key, value: value)
    }

    func get(_ key: String) throws -> Data? {
        try store.get(key: key)
    }

    func remove(_ key: String) throws {
        try store.remove(key: key)
    }

    func entries(withPrefix prefix: String) throws -> [(key: String, value: Data)] {
        try store.entriesWithPrefix(prefix: prefix).map { (key: $0.key, value: $0.value) }
    }
}
