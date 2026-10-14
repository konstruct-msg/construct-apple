//
//  LocalStoreImport.swift
//  Construct Messenger
//
//  iOS moves from Core Data to `construct.db` once, on the first launch after the update
//  (LOCAL_STORE_MIGRATION_PLAN step 4, decided with the owner 2026-10-14: a screen while it runs).
//
//  Every row is read from the Core Data repositories and written through the same protocols into
//  the store, then both are read back by those protocols and compared. The history projection
//  (CTM1) is not used: it leaves out what a device link has no use for — processed ids, server
//  ids, chunks in flight, the invite journal — and without the processed ids an import would
//  process again what was already processed.
//
//  It runs before the network does, so nothing writes to Core Data meanwhile and nothing written
//  during the copy can be left behind (`StoreImportGate` says when).
//

import CoreData
import Foundation

enum LocalStoreImport {

    /// The last write of a finished import, inside the store it describes: a `construct.db`
    /// without it is an import that did not finish, and is wiped and run again.
    static let completedKey = "construct.localStore.importedFromCoreData.v1"
    static let messagePage = 200
    /// No real call log comes near it; `CallStore.calls` takes a limit and the store's is 32-bit.
    static let callLimit = 1_000_000

    /// What no repository lists — Core Data's own service rows — and whose profile to carry.
    struct Extras {
        var processedMarks: () throws -> [(messageId: String, senderId: String, at: Date)]
        var serverIds: () throws -> [(serverId: String, localId: String, at: Date)]
        var ownAccountId: String?
    }

    static func coreDataExtras(_ container: NSPersistentContainer, ownAccountId: String?) -> Extras {
        let processed = CoreDataProcessedMessageStore(container: container)
        let serverIds = CoreDataServerMessageIdStore(container: container)
        return Extras(processedMarks: processed.everyMark, serverIds: serverIds.everyMapping, ownAccountId: ownAccountId)
    }

    struct Counts: Equatable {
        var contacts = 0, peerDevices = 0, chats = 0, messages = 0, reactions = 0, calls = 0
        var processed = 0, serverIds = 0, pendingChunks = 0, keyValues = 0, invites = 0
        var ownProfile = false
    }

    enum Failure: Error, Equatable {
        /// What was read back differs from what was written; the domain and the first difference.
        case mismatch(String)
    }

    /// Whether this install stands on `construct.db`: always on macOS; on iOS from the import
    /// on. Set only after the store holds `completedKey`, so it never names a half-written store;
    /// read before the store can be opened — a background launch before the first unlock must
    /// still know which store it may not fall back from.
    static var hasMoved: Bool {
        #if os(macOS)
        true
        #else
        UserDefaults.standard.bool(forKey: movedKey)
        #endif
    }

    static let movedKey = "construct.localStore.active.v1"

    /// Whether this launch moves the install. Not in a unit-test host: the tests run inside the
    /// app on the simulator, and an import there would move the simulator's store under them —
    /// every test after it on a store it did not set up. The import itself is tested directly
    /// (`LocalStoreImportTests`).
    static var isDueAtLaunch: Bool {
        !hasMoved && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    static func markMoved() {
        UserDefaults.standard.set(true, forKey: movedKey)
    }

    #if os(iOS)
    /// After the move, what Core Data and the iOS service stores left behind: the SQLite store,
    /// the per-message key database, partial-message files, the invite journal and retry queue
    /// in `UserDefaults`. Run at launch, before anything opens them — Core Data is in memory from
    /// the move on (`PersistenceController.shared`). Media stay: they are sealed under
    /// `LocalStoreKey`, which the store uses too.
    static func removeCoreDataLeftovers() {
        guard hasMoved else { return }
        let fm = FileManager.default
        let store = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("ConstructMessenger.sqlite")
        let keyDatabase = MessageKeyStore.storageURL
        let leftovers = PersistenceController.sqliteFiles(of: store) + PersistenceController.sqliteFiles(of: keyDatabase)
            + [FilePendingChunkStore.defaultRoot]
        var removed = 0
        for url in leftovers where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                Log.error("LocalStoreImport: could not remove \(url.lastPathComponent) — \(error)", category: "Storage")
            }
        }
        for key in keyValueKeys + [DefaultsIssuedInviteStore.storageKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if removed > 0 {
            Log.info("LocalStoreImport: removed \(removed) Core Data leftover(s)", category: "Storage")
        }
    }
    #endif

    static func isComplete(_ store: LocalRepositories.Backing) -> Bool {
        (try? store.keyValue.get(completedKey)) != nil
    }

    /// Copy everything `source` holds into `destination`, which is new and empty, check it, and
    /// mark it complete. `progress` goes from 0 to 1 with the messages, which are most of it.
    @discardableResult
    static func run(
        from source: LocalRepositories.Backing,
        extras: Extras,
        into destination: LocalRepositories.Backing,
        progress: (Double) -> Void = { _ in }
    ) throws -> Counts {
        var counts = Counts()
        progress(0)

        if let account = extras.ownAccountId, let profile = try source.ownProfile.profile(accountId: account) {
            try destination.ownProfile.save(profile)
            counts.ownProfile = true
        }
        // Contacts before chats, chats before messages: each names the one before it. Not our own
        // row: Core Data keeps the profile in the contacts table, `construct.db` in its own, and a
        // copy of it among the contacts would be a contact named after us.
        for contact in try source.contacts.everyContact(except: extras.ownAccountId) {
            try destination.contacts.insert(contact)
            counts.contacts += 1
        }
        let devices = try source.peerDevices.allDevices()
        _ = try destination.peerDevices.record(devices)
        counts.peerDevices = devices.count

        let chats = try source.chats.chats()
        for chat in chats {
            try destination.chats.insert(chat)
        }
        counts.chats = chats.count

        let expected = max(1, try chats.reduce(0) { $0 + (try source.messages.messageCount(inChat: $1.id)) })
        var cursor: (orderKey: String, id: String)?
        while true {
            let page = try source.messages.allMessages(after: cursor, limit: messagePage)
            guard let last = page.last else { break }
            try destination.messages.insert(page.map {
                (message: $0, searchText: LocalMessagePayload.decode($0.body).plainText)
            })
            counts.messages += page.count
            cursor = (last.orderKey, last.id)
            progress(min(0.95, Double(counts.messages) / Double(expected)))
        }

        for reaction in try source.reactions.allReactions() {
            try destination.reactions.upsert(reaction)
            counts.reactions += 1
        }
        for call in try source.calls.calls(limit: callLimit) {
            try destination.calls.upsert(call)
            counts.calls += 1
        }
        for mark in try extras.processedMarks() {
            _ = try destination.processedMessages.markProcessed(mark.messageId, senderId: mark.senderId, at: mark.at)
            counts.processed += 1
        }
        for mapping in try extras.serverIds() {
            try destination.serverMessageIds.record(serverId: mapping.serverId, localId: mapping.localId, at: mapping.at)
            counts.serverIds += 1
        }
        for message in try source.pendingChunks.messages() {
            for chunk in try source.pendingChunks.chunks(senderId: message.senderId, messageId: message.messageId) {
                _ = try destination.pendingChunks.add(chunk)
                counts.pendingChunks += 1
            }
        }
        for key in keyValueKeys {
            guard let value = try source.keyValue.get(key) else { continue }
            try destination.keyValue.put(key, value)
            counts.keyValues += 1
        }
        for invite in try source.issuedInvites.all() {
            try destination.issuedInvites.record(invite)
            counts.invites += 1
        }

        try verify(source: source, extras: extras, destination: destination, counts: counts)
        try destination.keyValue.put(completedKey, Data([1]))
        progress(1)
        return counts
    }

    /// The key-value pairs the app keeps: one today. A new key read through
    /// `LocalRepositories.keyValue` is added here, or an import leaves it behind.
    static var keyValueKeys: [String] { [FanoutRetryQueue.storageKey] }

    // MARK: - Check

    /// Both stores read through the same protocols. The source side goes through the store's own
    /// conversion first: `construct.db` keeps milliseconds, Core Data finer, and a difference there
    /// is the format, not a lost row.
    private static func verify(
        source: LocalRepositories.Backing,
        extras: Extras,
        destination: LocalRepositories.Backing,
        counts: Counts
    ) throws {
        if let account = extras.ownAccountId {
            try same("own profile", try source.ownProfile.profile(accountId: account),
                     try destination.ownProfile.profile(accountId: account))
        }
        try sameSet("contacts",
                    try source.contacts.everyContact(except: extras.ownAccountId).map { ContactRecord($0.local) },
                    try destination.contacts.everyContact(except: nil), by: \.id)
        try sameSet("peer devices",
                    try source.peerDevices.allDevices().map { PeerDeviceRecord($0.local) },
                    try destination.peerDevices.allDevices(), by: \.deviceId)
        try sameSet("chats",
                    try source.chats.chats().map { ChatRecord($0.local) },
                    try destination.chats.chats(), by: \.id)

        var cursor: (orderKey: String, id: String)?
        var compared = 0
        while true {
            let left = try source.messages.allMessages(after: cursor, limit: messagePage)
            let right = try destination.messages.allMessages(after: cursor, limit: messagePage)
            guard left.count == right.count else {
                throw Failure.mismatch("messages: a page of \(left.count) read back as \(right.count) after \(compared)")
            }
            guard let last = left.last else { break }
            for (l, r) in zip(left, right) where MessageRecord(l.local) != r {
                throw Failure.mismatch("messages: \(l.id) read back as \(r.id) or with other fields")
            }
            compared += left.count
            cursor = (last.orderKey, last.id)
        }
        try same("message count", counts.messages, compared)

        try sameSet("reactions",
                    try source.reactions.allReactions().map { ReactionRecord($0.local) },
                    try destination.reactions.allReactions(), by: { "\($0.targetMessageId)|\($0.reactorUserId)" })
        try sameSet("calls",
                    try source.calls.calls(limit: callLimit).map { CallRecord($0.local) },
                    try destination.calls.calls(limit: callLimit), by: \.id)

        for mark in try extras.processedMarks() where !(try destination.processedMessages.isProcessed(mark.messageId)) {
            throw Failure.mismatch("processed: \(mark.messageId) missing")
        }
        for mapping in try extras.serverIds() {
            try same("server id \(mapping.serverId)", mapping.localId.lowercased(),
                     try destination.serverMessageIds.localId(forServerId: mapping.serverId))
        }

        try sameSet("chunk messages", try source.pendingChunks.messages(), try destination.pendingChunks.messages(),
                    by: { "\($0.senderId)|\($0.messageId)" })
        for message in try source.pendingChunks.messages() {
            let key: (PendingChunkRecord) -> String = { "\($0.chunkIndex)" }
            try sameSet("chunks of \(message.messageId)",
                        try source.pendingChunks.chunks(senderId: message.senderId, messageId: message.messageId).map(Self.ms),
                        try destination.pendingChunks.chunks(senderId: message.senderId, messageId: message.messageId).map(Self.ms),
                        by: key)
        }
        for key in keyValueKeys {
            try same("key \(key)", try source.keyValue.get(key), try destination.keyValue.get(key))
        }
        try sameSet("invites", try source.issuedInvites.all().map(Self.ms), try destination.issuedInvites.all().map(Self.ms),
                    by: \.jti)
    }

    private static func same<T: Equatable>(_ what: String, _ left: T, _ right: T) throws {
        guard left == right else { throw Failure.mismatch(what) }
    }

    private static func sameSet<T: Equatable>(_ what: String, _ left: [T], _ right: [T], by key: (T) -> String) throws {
        guard left.count == right.count else {
            throw Failure.mismatch("\(what): \(left.count) written, \(right.count) read back")
        }
        let byKey = Dictionary(right.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for row in left where byKey[key(row)] != row {
            throw Failure.mismatch("\(what): \(key(row)) differs")
        }
    }

    private static func ms(_ chunk: PendingChunkRecord) -> PendingChunkRecord {
        PendingChunkRecord(
            senderId: chunk.senderId, messageId: chunk.messageId, chunkIndex: chunk.chunkIndex,
            totalChunks: chunk.totalChunks, plaintextLength: chunk.plaintextLength,
            contentType: chunk.contentType, payload: chunk.payload,
            receivedAt: Date(unixMs: chunk.receivedAt.unixMs)
        )
    }

    private static func ms(_ invite: IssuedInviteRecord) -> IssuedInviteRecord {
        IssuedInviteRecord(
            jti: invite.jti, kind: invite.kind, issuedAt: Date(unixMs: invite.issuedAt.unixMs),
            ttlSeconds: invite.ttlSeconds, sitting: invite.sitting
        )
    }
}
