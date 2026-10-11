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

    private init(store: LocalStore) {
        self.store = store
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

    /// Closes the store and deletes its files; every later call on `store` throws `Closed`. The
    /// key is the caller's: `LocalDataWipe` deletes it.
    func wipe() throws {
        try store.wipe()
    }

    #if DEBUG
    /// A store in memory only, under the same encryption path.
    static func inMemoryForTesting() -> LocalStoreSession {
        LocalStoreSession(store: try! LocalStore.inMemory(key: Data(repeating: 0x5A, count: 32)))
    }
    #endif
}
