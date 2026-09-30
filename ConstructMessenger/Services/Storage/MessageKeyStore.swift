//
//  MessageKeyStore.swift
//  Construct Messenger
//
//  Persistent store mapping message_id → 32-byte storage_key.
//
//  Architecture:
//  - Raw SQLite3 (libsqlite3) — no Core Data overhead, no WAL-file exposure
//  - journal_mode=DELETE keeps exactly one file on disk (no -wal / -shm)
//  - Thread-safe via a serial DispatchQueue (coreLock pattern)
//
//  Protection class is `completeUntilFirstUserAuthentication`, not the `complete` the spec
//  asks for. Keys are written from `Message.applyStoredEncryption` on the message-persistence
//  path, which runs during a background push decrypt on a locked device; `complete` would fail
//  the write there and leave a row whose ciphertext has no key. Same trade as the Keychain
//  invariant on `cryptoKeyAccessible`, and the cost is the same: an unlocked-once device.
//
//  Decrypt-on-display is live, not pending: `MessageDisplayCache.plaintext(of:)` reads
//  `contentKeyRef` → `fetch(messageId:)` → `MessageStorageCrypto.decrypt`, and
//  `applyStoredEncryption` clears `decryptedContent`. That column survives for two reasons
//  only — rows written before `StorageMigrationService` ran, and the fallback taken when
//  encryption itself fails.
//
//  The key is 32 random bytes per message (`SecRandomCopyBytes`), not HKDF over the Double
//  Ratchet message key as MESSAGE_STORAGE_PRIVACY_SPEC.md §Layer-1 describes. Nothing needs the
//  derivation: the key never leaves this device, so it has no counterpart to agree with. That
//  spec's Rust/FFI phase is therefore moot, not outstanding.
//
//  Since 2026-09-30 each key is stored sealed under `LocalStoreKey` (AES-256-GCM, bound to its
//  message id). Before that the keys lay here in the clear, next to the ciphertext they open, and
//  on macOS — where file protection does nothing — the at-rest encryption bought nothing. A
//  32-byte blob is a key from before that (or from a restored backup); opening the database seals
//  every one of them and rewrites the file with `secure_delete` on, so the clear bytes do not
//  survive in free pages.
//
//  See: MESSAGE_STORAGE_PRIVACY_SPEC.md (§Status 2026-08-28 records the divergences above)

import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro (-1 cast to destructor type) not imported by Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class MessageKeyStore {

    static let shared = MessageKeyStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ct.MessageKeyStore", qos: .userInitiated)

    // MARK: - Init

    private init() {
        queue.sync { self.openDatabase() }
    }

    // MARK: - Public API

    /// Persist a 32-byte storage key for a given message.
    /// - Parameters:
    ///   - messageId: Unique message identifier (UUID string).
    ///   - key:       32-byte storage key (from `DecryptedMessageResult.storageKey`).
    ///   - contactId: Contact/user identifier — used for bulk-delete on contact removal.
    func store(messageId: String, key: Data, contactId: String) {
        guard !key.isEmpty else { return }
        queue.async { [weak self] in
            self?.executeStore(messageId: messageId, key: key, contactId: contactId)
        }
    }

    /// Persist a 32-byte storage key synchronously.
    ///
    /// Must be used when the caller is about to save a Core Data context that
    /// will persist `contentKeyRef`. If the key write is deferred (async) and
    /// the process is killed before it runs, the message becomes permanently
    /// unreadable — `hasDecryptedContent` is true but `displayText` returns "".
    func storeSync(messageId: String, key: Data, contactId: String) {
        guard !key.isEmpty else { return }
        queue.sync { self.executeStore(messageId: messageId, key: key, contactId: contactId) }
    }

    /// Fetch the storage key for a message.
    /// Returns `nil` if not found (message predates key-store, or key was deleted).
    func fetch(messageId: String) -> Data? {
        queue.sync { self.executeFetch(messageId: messageId) }
    }

    /// Delete the storage key for a single message (forward-secret deletion).
    func delete(messageId: String) {
        queue.async { [weak self] in
            self?.executeDelete(messageId: messageId)
        }
    }

    /// Delete all storage keys for a contact (e.g. on contact removal or chat wipe).
    func deleteAll(for contactId: String) {
        queue.async { [weak self] in
            self?.executeDeleteAll(contactId: contactId)
        }
    }

    /// VACUUM the database. Call periodically (e.g. on app backgrounding) after large deletions.
    /// Close the database so its file can be removed with the account; the next call opens a
    /// fresh, empty one (`database()`). `LocalDataWipe` only.
    func close() {
        queue.sync {
            if let db { sqlite3_close(db) }
            db = nil
        }
    }

    func vacuum() {
        queue.async { [weak self] in
            guard let db = self?.database() else { return }
            sqlite3_exec(db, "VACUUM;", nil, nil, nil)
        }
    }

    // MARK: - Private implementation

    private func openDatabase() {
        let url = Self.databaseURL()

        var pointer: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &pointer,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let ptr = pointer else {
            Log.error("MessageKeyStore: failed to open database at \(url.path)", category: "MessageKeyStore")
            return
        }
        db = ptr

        applyFileProtection(at: url)
        configurePragmas()
        createSchema()
        sealLegacyKeys()
    }

    /// Returns the open DB handle, retrying `openDatabase()` if a previous open
    /// failed. The first open can fail when the process launches before the first
    /// unlock following boot (the protected file is not yet accessible). Without
    /// this, `db` would stay nil for the whole process lifetime and every key
    /// read/write would silently fail. Must be called on `queue`.
    private func database() -> OpaquePointer? {
        if db == nil { openDatabase() }
        return db
    }

    private func configurePragmas() {
        guard let db else { return }
        // Delete journal keeps the store as a single file (no -wal / -shm exposure).
        sqlite3_exec(db, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=FULL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        // Overwritten and deleted cells are zeroed, not left in free pages: a key replaced by its
        // sealed form, or deleted with its message, must not be recoverable from the file.
        sqlite3_exec(db, "PRAGMA secure_delete=ON;", nil, nil, nil)
    }

    private func createSchema() {
        guard let db else { return }
        let ddl = """
            CREATE TABLE IF NOT EXISTS message_keys (
                message_id  TEXT    PRIMARY KEY NOT NULL,
                storage_key BLOB    NOT NULL,
                contact_id  TEXT    NOT NULL,
                created_at  INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_message_keys_contact
                ON message_keys(contact_id);
        """
        if sqlite3_exec(db, ddl, nil, nil, nil) != SQLITE_OK {
            Log.error("MessageKeyStore: schema creation failed: \(sqliteError())", category: "MessageKeyStore")
        }
    }

    // MARK: - CRUD

    private func executeStore(messageId: String, key: Data, contactId: String) {
        guard let db = database() else { return }
        guard let storeKey = LocalStoreKey.current(),
              let sealed = try? AtRestSeal.seal(key, under: storeKey, boundTo: messageId) else {
            // Never the clear key instead: a row readable from a copy of the container is what
            // this store stopped writing. The message shows as unavailable; the log says why.
            Log.error("MessageKeyStore: no store key — key for \(messageId.prefix(8))… not written", category: "MessageKeyStore")
            return
        }
        let sql = """
            INSERT OR REPLACE INTO message_keys (message_id, storage_key, contact_id, created_at)
            VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.error("MessageKeyStore: prepare store failed: \(sqliteError())", category: "MessageKeyStore")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)
        sealed.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(sealed.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(stmt, 3, contactId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, Int64(Date().timeIntervalSince1970))

        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.error("MessageKeyStore: store failed for \(messageId.prefix(8))…: \(sqliteError())", category: "MessageKeyStore")
        }
    }

    private func executeFetch(messageId: String) -> Data? {
        guard let db = database() else { return nil }
        let sql = "SELECT storage_key FROM message_keys WHERE message_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        return Self.unsealed(Data(bytes: blob, count: count), messageId: messageId)
    }

    /// A stored blob as the key it holds: a clear 32-byte key from before sealing (only until
    /// `sealLegacyKeys` reaches it), or a sealed one.
    private static func unsealed(_ blob: Data, messageId: String) -> Data? {
        if blob.count == Self.clearKeyLength { return blob }
        guard let storeKey = LocalStoreKey.current() else { return nil }
        do {
            return try AtRestSeal.open(blob, under: storeKey, boundTo: messageId)
        } catch {
            Log.error("MessageKeyStore: key for \(messageId.prefix(8))… does not open: \(error)", category: "MessageKeyStore")
            return nil
        }
    }

    private static let clearKeyLength = 32

    /// Seal every clear key — rows from before 2026-09-30 and rows a backup restored — and
    /// rewrite the file so their clear bytes are gone. Runs on open; a device without its store
    /// key yet (before first unlock) leaves them for the next open.
    private func sealLegacyKeys() {
        guard let db else { return }
        let select = "SELECT message_id, storage_key FROM message_keys WHERE length(storage_key) = \(Self.clearKeyLength);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK else { return }
        var clear: [(String, Data)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0), let blob = sqlite3_column_blob(stmt, 1) else { continue }
            clear.append((String(cString: idPtr), Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))))
        }
        sqlite3_finalize(stmt)
        guard !clear.isEmpty, let storeKey = LocalStoreKey.current() else { return }

        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        var update: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE message_keys SET storage_key = ? WHERE message_id = ?;", -1, &update, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
        var sealedCount = 0
        for (messageId, key) in clear {
            guard let sealed = try? AtRestSeal.seal(key, under: storeKey, boundTo: messageId) else { continue }
            sqlite3_reset(update)
            sealed.withUnsafeBytes { ptr in
                _ = sqlite3_bind_blob(update, 1, ptr.baseAddress, Int32(sealed.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_text(update, 2, messageId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(update) == SQLITE_DONE { sealedCount += 1 }
        }
        sqlite3_finalize(update)
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            Log.error("MessageKeyStore: sealing clear keys failed: \(sqliteError())", category: "MessageKeyStore")
            return
        }
        sqlite3_exec(db, "VACUUM;", nil, nil, nil)
        Log.info("MessageKeyStore: sealed \(sealedCount) clear key(s)", category: "MessageKeyStore")
    }

    // MARK: - Portable copy

    /// The key database with every key in the clear, for a backup that is itself encrypted
    /// (`LocalBackupService`): sealed under this device's store key it would open nowhere else.
    /// Built in memory and serialized — the clear keys never touch this device's disk. The device
    /// that restores it seals them on its first open (`sealLegacyKeys`).
    func portableCopy() -> Data? {
        queue.sync {
            guard let db = database() else { return nil }
            var mem: OpaquePointer?
            guard sqlite3_open(":memory:", &mem) == SQLITE_OK, let mem else { return nil }
            defer { sqlite3_close(mem) }
            let ddl = """
                CREATE TABLE message_keys (
                    message_id  TEXT    PRIMARY KEY NOT NULL,
                    storage_key BLOB    NOT NULL,
                    contact_id  TEXT    NOT NULL,
                    created_at  INTEGER NOT NULL
                );
                CREATE INDEX idx_message_keys_contact ON message_keys(contact_id);
            """
            guard sqlite3_exec(mem, ddl, nil, nil, nil) == SQLITE_OK else { return nil }

            var read: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT message_id, storage_key, contact_id, created_at FROM message_keys;", -1, &read, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(read) }
            var write: OpaquePointer?
            guard sqlite3_prepare_v2(mem, "INSERT INTO message_keys VALUES (?, ?, ?, ?);", -1, &write, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(write) }

            sqlite3_exec(mem, "BEGIN;", nil, nil, nil)
            while sqlite3_step(read) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(read, 0), let blob = sqlite3_column_blob(read, 1),
                      let contactPtr = sqlite3_column_text(read, 2) else { continue }
                let messageId = String(cString: idPtr)
                let stored = Data(bytes: blob, count: Int(sqlite3_column_bytes(read, 1)))
                guard let key = Self.unsealed(stored, messageId: messageId) else { continue }
                sqlite3_reset(write)
                sqlite3_bind_text(write, 1, messageId, -1, SQLITE_TRANSIENT)
                key.withUnsafeBytes { ptr in
                    _ = sqlite3_bind_blob(write, 2, ptr.baseAddress, Int32(key.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_text(write, 3, contactPtr, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(write, 4, sqlite3_column_int64(read, 3))
                sqlite3_step(write)
            }
            sqlite3_exec(mem, "COMMIT;", nil, nil, nil)

            var size: sqlite3_int64 = 0
            guard let bytes = sqlite3_serialize(mem, "main", &size, 0) else { return nil }
            defer { sqlite3_free(bytes) }
            return Data(bytes: bytes, count: Int(size))
        }
    }

    #if DEBUG
    /// Test seam: the blob as stored, to check it is not the clear key.
    func storedBlobForTesting(messageId: String) -> Data? {
        queue.sync {
            guard let db = database() else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT storage_key FROM message_keys WHERE message_id = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
        }
    }
    #endif

    private func executeDelete(messageId: String) {
        guard let db = database() else { return }
        let sql = "DELETE FROM message_keys WHERE message_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    private func executeDeleteAll(contactId: String) {
        guard let db = database() else { return }
        let sql = "DELETE FROM message_keys WHERE contact_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, contactId, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Helpers

    private func sqliteError() -> String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// Public accessor for the database file path (used by LocalBackupService for export/restore).
    static var storageURL: URL { databaseURL() }

    private static func databaseURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ct_secure", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("message_keys.sqlite")
    }

    private func applyFileProtection(at url: URL) {
        do {
            // Must match the Core Data store protection level
            // (PersistenceController uses .completeUntilFirstUserAuthentication).
            // The encrypted message *content* lives in Core Data and is readable after
            // first unlock; the *key* lives here. Using the stricter .complete made the
            // key inaccessible whenever the device is locked, so any locked/background
            // launch opened this DB with a "disk I/O error" (db stayed nil for the whole
            // process) → every at-rest message rendered "Message not available", and keys
            // for messages received while locked were never written at all.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            Log.info("MessageKeyStore: could not set file protection on \(url.lastPathComponent): \(error)", category: "MessageKeyStore")
        }
    }
}
