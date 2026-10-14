//
//  LocalStoreSession.swift
//  Construct Messenger
//
//  The app's one `LocalStore` (construct-store): `Application Support/construct.db`, SQLCipher
//  under `LocalStoreKey`. LOCAL_STORE_MIGRATION_PLAN step 3; `decisions/local-store-in-the-core.md`.
//

import CryptoKit
import Foundation

/// An open store, or why there is none. **No failure creates a store**: every one of them means
/// the data is probably still on this device and something would not hand it over — the
/// 2026-08-09 lesson of `DeviceKeyAvailability`, at the scale of the whole transcript. A fresh
/// empty store over it is how an account loses its history without an error.
final class LocalStoreSession: Sendable {

    enum Failure: Error, Equatable {
        /// The Keychain did not answer (before the first unlock, a damaged item). Not opened, so
        /// not created either.
        case keyUnavailable
        /// The file is there and the key is not its key.
        case wrongKey
        /// Written by a newer build; this one must not read or migrate it.
        case schemaTooNew
        case storage(String)
    }

    let store: LocalStore
    private let feed = LocalStoreFeed()

    private init(store: LocalStore) {
        self.store = store
        store.setObserver(observer: feed)
    }

    /// The ids of `table`'s rows written or deleted, once per committed write — what a
    /// repository's `changes()` hands the screens. Subscribe before the first read, or a write
    /// between the two is missed.
    func changes(of table: LocalStoreTable) -> AsyncStream<Set<String>> {
        feed.stream(table)
    }

    static var defaultURL: URL {
        get throws {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            return dir.appendingPathComponent("construct.db")
        }
    }

    /// `key` is `LocalStoreKey.current()` in the app; `nil` is its "Keychain did not answer".
    static func open(at url: URL, key: SymmetricKey?) -> Result<LocalStoreSession, Failure> {
        guard let key else { return .failure(.keyUnavailable) }
        do {
            let store = try LocalStore(path: url.path, key: key.withUnsafeBytes { Data($0) })
            #if os(iOS)
            // A push is decrypted and stored with the phone locked: the store must stay readable
            // after the first unlock, as the Core Data store and the keys are. iOS's default class
            // for app files is this one; said here rather than relied on.
            for file in PersistenceController.sqliteFiles(of: url) where FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path
                )
            }
            #endif
            return .success(LocalStoreSession(store: store))
        } catch {
            let failure = failure(for: error)
            Log.error("LocalStoreSession: not opened — \(failure)", category: "Storage")
            return .failure(failure)
        }
    }

    static func failure(for error: Error) -> Failure {
        switch error {
        case LocalStoreError.WrongKey: return .wrongKey
        case LocalStoreError.SchemaTooNew: return .schemaTooNew
        default: return .storage("\(error)")
        }
    }

    /// Closes the store and deletes its files; every later call on `store` throws `Closed`, and
    /// every `changes` stream ends. The key is the caller's: `LocalRepositories.replaceAppStore`
    /// deletes it first.
    func wipe() throws {
        defer { feed.finishAll() }
        try store.wipe()
    }

    /// A store every call on throws `Closed`: what the repositories stand on when the app's store
    /// would not open, so a write fails where it is made — a delivery is then not acknowledged as
    /// stored — instead of landing somewhere that is not the account's store.
    static func closed() -> LocalStoreSession {
        // Any key: the store is closed before anything is written to it.
        let store = try? LocalStore.inMemory(key: Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }))
        try? store?.wipe()
        guard let store else { preconditionFailure("an in-memory store did not open") }
        return LocalStoreSession(store: store)
    }

    #if DEBUG
    /// A store in memory only, under the same encryption path.
    static func inMemoryForTesting() -> LocalStoreSession {
        LocalStoreSession(store: try! LocalStore.inMemory(key: Data(repeating: 0x5A, count: 32)))
    }
    #endif
}

/// The core's observer, fanned out by table. `on_change` arrives on the writing thread after the
/// commit, never under the store's lock.
private final class LocalStoreFeed: LocalStoreObserver, @unchecked Sendable {

    private let lock = NSLock()
    private var subscribers: [UUID: (table: LocalStoreTable, continuation: AsyncStream<Set<String>>.Continuation)] = [:]

    func stream(_ table: LocalStoreTable) -> AsyncStream<Set<String>> {
        AsyncStream { continuation in
            let key = UUID()
            lock.withLock { subscribers[key] = (table, continuation) }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: key) }
            }
        }
    }

    func finishAll() {
        let all = lock.withLock {
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        all.forEach { $0.continuation.finish() }
    }

    func onChange(change: LocalStoreChange) {
        let ids = Set(change.ids)
        guard !ids.isEmpty else { return }
        let targets = lock.withLock { subscribers.values.filter { $0.table == change.table } }
        targets.forEach { $0.continuation.yield(ids) }
    }
}
