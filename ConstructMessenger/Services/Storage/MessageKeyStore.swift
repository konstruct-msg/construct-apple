//
//  MessageKeyStore.swift
//  Construct Messenger
//
//  Persistent store mapping message_id → 32-byte storage_key.
//
//  Architecture:
//  - Raw SQLite3 (libsqlite3) — no Core Data overhead, no WAL-file exposure
//  - journal_mode=DELETE keeps exactly one file on disk (no -wal / -shm)
//  - NSFileProtectionComplete set on the database file after first open
//  - Thread-safe via a serial DispatchQueue (coreLock pattern)
//
//  This store is the foundation for decrypt-on-display (Phase 3).
//  Currently callers store the key here and read it back when displaying
//  a message. Once Core Data is migrated off decryptedContent, display will
//  call fetch(messageId:) → decrypt-on-the-fly.
//
//  See: MESSAGE_STORAGE_PRIVACY_SPEC.md

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
        key.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(key.count), SQLITE_TRANSIENT)
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
        return Data(bytes: blob, count: count)
    }

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
