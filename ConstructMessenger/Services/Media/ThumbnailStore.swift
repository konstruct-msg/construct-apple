//
//  ThumbnailStore.swift
//  Construct Messenger
//
//  Message thumbnails on disk, because they were in NSUserDefaults.
//
//  `MediaManager` carried this, under a header that named itself: "Thumbnail Storage (UserDefaults
//  - temporary solution)". It stored JPEG bytes under `message_thumbnail_<messageId>_<index>`, and
//  for index 0 it wrote the same bytes a second time under a legacy unindexed key. Device,
//  2026-08-11 15:38:44, measured at launch:
//
//      USERDEFAULTS: total=37785KB keys=1145 limit=4096KB OVER-LIMIT
//      USERDEFAULTS:   14945KB  message_thumbnail_*    (426 key(s))
//      USERDEFAULTS:   14945KB  message_thumbnail_*_0  (426 key(s))
//      USERDEFAULTS:   2633KB   message_thumbnail_*_1  (67 key(s))
//
//  Nine times the 4 MB CFPreferences limit, ~95% of the domain, and the top two rows are the same
//  426 images written twice. Past that limit CFPreferences starts refusing writes — which is how a
//  thumbnail cache took down settings, session flags and stream cursors that live in the same
//  domain. It is also 37 MB resident: UserDefaults keeps the whole domain in memory.
//
//  Three things this fixes, and they are separate:
//
//    1. Thumbnails move to `Library/Caches/thumbnails/`. They are derived data — losing one to an
//       OS purge costs a preview, not a message.
//    2. The duplicate index-0 write stops. Reads still fall back to the legacy key, so existing
//       thumbnails keep working until they migrate.
//    3. Existing keys are drained, both in bulk at launch and lazily on read. Bulk alone would miss
//       nothing here, but read-path-only cleanup is exactly the mistake that let
//       `OutgoingWirePayloadStore` accumulate: a rule that only runs when someone asks for that
//       specific key never reaches the entries nobody asks for.
//
//  On the ~35 KB average seen on that device: the budget already exists and is 12 KB
//  (`MediaOptimizer.thumbnailMaxBytes`), added after a three-photo album turned into 30 wire
//  messages and spent 30 stealth tokens. The oversized entries are simply older than the cap, so
//  they drain rather than accumulate. No quota here for that reason — on disk this is ~15 MB of
//  Caches the OS may evict, and losing one costs a preview until the full image loads.
//

import Foundation

/// Pure key/filename handling, so the migration's parsing is testable without a filesystem.
enum ThumbnailKey {

    static let defaultsPrefix = "message_thumbnail_"

    /// Splits a legacy UserDefaults key back into the message id and image index.
    ///
    /// Both spellings existed: `message_thumbnail_<id>_<n>` and, for index 0 only,
    /// `message_thumbnail_<id>`. A trailing `_<digits>` is therefore read as the index and anything
    /// else as index 0.
    ///
    /// ASSUMPTION, stated because it is load-bearing: message ids here are UUID strings, which
    /// contain no underscores. An id that itself ended in `_7` would have its last component eaten
    /// as an index. Nothing in this codebase mints such an id — `Sending message with ID:` is a
    /// UUID on every path — but if that ever changes, this is where it breaks.
    static func parse(defaultsKey: String) -> (messageId: String, index: Int)? {
        guard defaultsKey.hasPrefix(defaultsPrefix) else { return nil }
        let body = String(defaultsKey.dropFirst(defaultsPrefix.count))
        guard !body.isEmpty else { return nil }

        if let underscore = body.lastIndex(of: "_") {
            let suffix = body[body.index(after: underscore)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let index = Int(suffix) {
                let messageId = String(body[body.startIndex..<underscore])
                if !messageId.isEmpty { return (messageId, index) }
            }
        }
        return (body, 0)
    }

    /// Filename for a thumbnail. Anything outside the UUID alphabet is replaced so a message id can
    /// never escape the directory or collide with a path separator.
    static func filename(messageId: String, index: Int) -> String {
        let safe = messageId.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }
        return "\(String(safe))_\(index)"
    }

    /// Files belonging to one message, used when the message is deleted.
    static func belongsToMessage(file: String, messageId: String) -> Bool {
        let stem = filename(messageId: messageId, index: 0).dropLast(2)   // strip the "_0"
        return file.hasPrefix("\(stem)_")
    }
}

final class ThumbnailStore {

    static let shared = ThumbnailStore()

    private let directory: URL
    private let defaults: UserDefaults

    /// Views call `retrieveThumbnail` synchronously inside `body`, so every read used to be a
    /// dictionary lookup in an in-memory domain. Going to disk without this would trade a memory
    /// problem for a scrolling one. NSCache also drops itself under pressure, which is the right
    /// behaviour for derived data.
    private let memory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 120
        return cache
    }()

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            return caches.appendingPathComponent("thumbnails", isDirectory: true)
        }()
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Storage

    func store(_ data: Data, for messageId: String, at index: Int) {
        let name = ThumbnailKey.filename(messageId: messageId, index: index)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        memory.setObject(data as NSData, forKey: name as NSString)
    }

    func load(for messageId: String, at index: Int) -> Data? {
        let name = ThumbnailKey.filename(messageId: messageId, index: index)
        if let cached = memory.object(forKey: name as NSString) { return cached as Data }

        if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) {
            memory.setObject(data as NSData, forKey: name as NSString)
            return data
        }

        // Not migrated yet: take it from UserDefaults, put it where it belongs, and drop the key.
        if let data = legacyData(messageId: messageId, index: index) {
            store(data, for: messageId, at: index)
            removeLegacyKeys(messageId: messageId, index: index)
            return data
        }
        return nil
    }

    func remove(for messageId: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where ThumbnailKey.belongsToMessage(file: file, messageId: messageId) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            memory.removeObject(forKey: file as NSString)
        }
        // Legacy keys for a deleted message must go even if they were never read.
        for index in 0..<10 { removeLegacyKeys(messageId: messageId, index: index) }
    }

    // MARK: - Migration

    /// Moves every remaining `message_thumbnail_*` value to disk and deletes the key.
    ///
    /// Returns the number of keys drained, so the log can say whether the domain actually shrank.
    @discardableResult
    func migrateFromUserDefaults() -> (keys: Int, bytes: Int) {
        let keys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(ThumbnailKey.defaultsPrefix) }
        guard !keys.isEmpty else { return (0, 0) }

        var bytes = 0
        for key in keys {
            guard let parsed = ThumbnailKey.parse(defaultsKey: key) else { continue }
            if let data = defaults.data(forKey: key) {
                bytes += data.count
                // Only write if the file is missing: the legacy unindexed key holds a duplicate of
                // index 0, and re-writing it would be pointless work on every migrated message.
                let name = ThumbnailKey.filename(messageId: parsed.messageId, index: parsed.index)
                let url = directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? data.write(to: url, options: .atomic)
                }
            }
            defaults.removeObject(forKey: key)
        }
        return (keys.count, bytes)
    }

    // MARK: - Legacy helpers

    private func legacyData(messageId: String, index: Int) -> Data? {
        if let data = defaults.data(forKey: "\(ThumbnailKey.defaultsPrefix)\(messageId)_\(index)") {
            return data
        }
        if index == 0 {
            return defaults.data(forKey: "\(ThumbnailKey.defaultsPrefix)\(messageId)")
        }
        return nil
    }

    private func removeLegacyKeys(messageId: String, index: Int) {
        defaults.removeObject(forKey: "\(ThumbnailKey.defaultsPrefix)\(messageId)_\(index)")
        if index == 0 {
            defaults.removeObject(forKey: "\(ThumbnailKey.defaultsPrefix)\(messageId)")
        }
    }
}
