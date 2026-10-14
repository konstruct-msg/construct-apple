//
//  PersistenceController.swift
//  Construct Messenger
//
//  Cross-platform Core Data stack.
//  Used by both the iOS target (ConstructMessengerApp) and the
//  native macOS target (ConstructMessengerMacApp).
//
//  The iOS/macOS apps each get their OWN SQLite store in their respective
//  Application Support directory — same schema, separate files.
//  iCloud/CloudKit sync can be added later to share data across platforms.
//

import CoreData

/// Cross-platform wrapper for the shared NSPersistentContainer.
/// Self-contained: does not depend on any App struct.
struct PersistenceController {
    #if os(macOS)
    /// macOS keeps the account in construct-store (`LocalRepositories`). Core Data there is in
    /// memory, for the code that still names a context, and the file older builds left is never
    /// opened again — neither read nor written in the clear.
    static let shared = PersistenceController(inMemory: true)
    #else
    /// iOS: the file until the install has moved to construct-store (`LocalStoreImport`), then in
    /// memory as on macOS — the file is removed at that launch (`removeCoreDataLeftovers`).
    static let shared = LocalStoreImport.hasMoved ? PersistenceController(inMemory: true) : PersistenceController()
    #endif

    /// In-memory store for SwiftUI previews and unit tests.
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        return controller
    }()

    let container: NSPersistentContainer

    /// The one model every store in the process is built from. iOS 26: `NSPersistentContainer(name:)`
    /// searches ALL bundles for the momd and may find it twice (main bundle + xcframework),
    /// registering NSEntityDescriptions twice — "Expected X but found X" casts on CallRecord /
    /// CTCallRecord. So it is loaded from Bundle.main, and loaded once: until 2026-10-06 each
    /// `init` loaded its own copy, and with several stores alive (tests make many in-memory ones)
    /// `User(context:)`, which finds its entity by class across every loaded model, could take
    /// another store's — a save then failed with Cocoa 133010 or raised on a temporary object id
    /// (TODO 120).
    private static let model: NSManagedObjectModel? = Bundle.main
        .url(forResource: "ConstructMessenger", withExtension: "momd")
        .flatMap(NSManagedObjectModel.init(contentsOf:))

    init(inMemory: Bool = false) {
        guard let model = Self.model else {
            // Bundle is corrupted — fall back to letting CoreData find the model itself.
            // Better to start with a potentially broken container than to crash outright.
            Log.error("Core Data: ConstructMessenger.momd not found in Bundle.main — falling back to default init")
            let fallback = NSPersistentContainer(name: "ConstructMessenger")
            fallback.loadPersistentStores { _, _ in }
            container = fallback
            return
        }
        let c = NSPersistentContainer(name: "ConstructMessenger", managedObjectModel: model)

        if !inMemory {
            LocalBackupService.applyPendingRestoreIfNeeded()
        }

        if inMemory {
            c.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else if let description = c.persistentStoreDescriptions.first {
            description.shouldInferMappingModelAutomatically = true
            description.shouldMigrateStoreAutomatically = true
            // Deleted and overwritten rows are zeroed rather than left in free pages: a message
            // deleted, or a clear body the storage migration replaced, must not be readable
            // from the file afterwards. SQLite applies it to pages freed from now on.
            description.setOption(["secure_delete": "ON"] as NSDictionary, forKey: NSSQLitePragmasOption)
            // .completeUntilFirstUserAuthentication (not .complete) allows the store to be
            // created and opened on first launch and from background wakes. .complete would
            // block file I/O until the device is unlocked AND can race with store creation
            // on first install (observed crash on iOS 26 / iPad16).
            #if os(iOS)
            description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                                  forKey: NSPersistentStoreFileProtectionKey)
            #endif
        }

        c.loadPersistentStores { description, error in
            guard let error else { return }
            // Store failed to load (e.g. schema migration or file protection error).
            // Recovery: wipe the incompatible store files and recreate a blank store so
            // the app can start. The user loses local cache but won't see a crash.
            Log.error("Core Data: store load failed — attempting recovery: \(error)")
            guard let storeURL = description.url else {
                // No URL at all — nothing we can do but log and continue with a
                // broken container (app will show empty state instead of crashing).
                Log.error("Core Data: persistent store has no URL — cannot recover")
                return
            }
            Self.nukeSQLiteFiles(at: storeURL)
            do {
                try c.persistentStoreCoordinator.addPersistentStore(
                    ofType: NSSQLiteStoreType,
                    configurationName: nil,
                    at: storeURL,
                    options: [
                        NSMigratePersistentStoresAutomaticallyOption: true,
                        NSInferMappingModelAutomaticallyOption: true
                    ]
                )
                Log.error("Core Data: store recreated after recovery — local data cleared")
            } catch {
                // Still failed after nuke — log and continue; the app will start with
                // an in-memory-like empty context rather than crashing.
                Log.error("Core Data: recovery failed after nuke: \(error)")
            }
        }

        c.viewContext.automaticallyMergesChangesFromParent = true
        c.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container = c

        migrateExistingContactsToSynaps()
        repairFutureTimestamps()
        backfillMissingServerOrderKeys()
        Self.settleDeliveredPendingRows(in: c.viewContext)
        DuplicateChats.merge(in: c.viewContext)
    }

    /// Rows of ours the peer confirmed that still carry the `pending` key — written before a
    /// receipt settled the order (`MessageStore.settleOrder(of:)`), the last ones on 2026-10-12.
    /// Normally empty.
    static func settleDeliveredPendingRows(in context: NSManagedObjectContext) {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(
            format: "isSentByMe == YES AND deliveryStatusRaw == %d AND serverOrderKey BEGINSWITH %@",
            DeliveryStatus.delivered.rawValue, ServerMessageOrder.pendingPrefix
        )
        guard let messages = try? context.fetch(request), !messages.isEmpty else { return }
        for message in messages {
            message.serverOrderKey = ServerMessageOrder.local(timestamp: message.safeTimestamp, messageId: message.id)
        }
        do {
            try context.save()
            Log.info("Settled the order of \(messages.count) delivered message(s) left pending", category: "Persistence")
        } catch {
            Log.error("Failed to settle pending order: \(error)", category: "Persistence")
        }
    }

    /// Pull any stored timestamp that lies in the future back to now, and repair the chat
    /// previews that such a timestamp froze.
    ///
    /// Remote timestamps used to be stored verbatim, so a peer with a fast clock could
    /// write a message — and therefore a `lastMessageTime` — ahead of real time. Since
    /// `Chat.applyPreview` refuses to move a preview backwards, that row then rejected
    /// every later message and stayed stuck on the stale text until wall-clock caught up.
    /// Ingestion now clamps (`Date.fromRemoteTimestamp`), but rows written before that
    /// still need pulling back.
    ///
    /// Deliberately NOT guarded by a one-time UserDefaults flag: the normal case is a
    /// fetch that matches nothing, and a flag would make the repair unrepeatable for
    /// anyone who acquired a bad row between updates.
    private func repairFutureTimestamps() {
        let context = container.viewContext
        let now = Date()

        let messageFetch = Message.fetchRequest()
        messageFetch.predicate = NSPredicate(format: "timestamp > %@", now as NSDate)
        let futureMessages = (try? context.fetch(messageFetch)) ?? []

        let chatFetch = Chat.fetchRequest()
        chatFetch.predicate = NSPredicate(format: "lastMessageTime > %@", now as NSDate)
        let futureChats = (try? context.fetch(chatFetch)) ?? []

        guard !futureMessages.isEmpty || !futureChats.isEmpty else { return }

        for message in futureMessages {
            message.timestamp = now
        }
        // Recompute from the (now clamped) newest surviving message rather than assigning
        // `now` — the preview text must match whatever the transcript actually ends with.
        for chat in futureChats {
            let newest = (chat.messages as? Set<Message>)?.max {
                ServerMessageOrder.effectiveKey(for: $0) < ServerMessageOrder.effectiveKey(for: $1)
            }
            if let newest {
                chat.applyPreview(text: newest.previewText, timestamp: newest.timestamp, force: true)
            } else {
                chat.lastMessageTime = now
            }
        }

        do {
            try context.save()
            Log.info(
                "Repaired future timestamps: \(futureMessages.count) message(s), \(futureChats.count) chat preview(s)",
                category: "Persistence"
            )
        } catch {
            Log.error("Failed to repair future timestamps: \(error)", category: "Persistence")
        }
    }

    /// Assign a deterministic key to rows written before transcript ordering became
    /// server-authoritative. Every path that creates a row now writes a server key, the pending
    /// sentinel or a local key, so this fetch is normally empty after the first launch on the new
    /// model — `TranscriptOrderIsTotalTests` is what holds that, not this comment: it used to say
    /// the same thing while the system-notice path left the column nil.
    private func backfillMissingServerOrderKeys() {
        let context = container.viewContext
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "serverOrderKey == nil")
        guard let messages = try? context.fetch(request), !messages.isEmpty else { return }

        for message in messages {
            message.serverOrderKey = ServerMessageOrder.local(
                timestamp: message.safeTimestamp,
                messageId: message.id
            )
        }

        do {
            try context.save()
            Log.info("Backfilled server order for \(messages.count) message(s)", category: "Persistence")
        } catch {
            Log.error("Failed to backfill server order: \(error)", category: "Persistence")
        }
    }

    /// One-time migration: marks all existing Users who have chats as isContact=true.
    /// Guarded by a UserDefaults flag so it only runs once after the update.
    private func migrateExistingContactsToSynaps() {
        let migrationKey = "synaps_contact_migration_v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let context = container.viewContext
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "isContact == NO AND chats.@count > 0")

        guard let users = try? context.fetch(fetch), !users.isEmpty else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        for user in users {
            user.isContact = true
            if user.addedAt == nil {
                let oldestChat = (user.chats as? Set<Chat>)?.compactMap(\.lastMessageTime).min()
                user.addedAt = oldestChat ?? Date()
            }
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: migrationKey)
            Log.info("Synaps migration: \(users.count) existing contact(s) moved to Synaps")
        } catch {
            Log.error("Synaps migration failed: \(error)")
        }
    }

    /// Empty the store by replacing its file rather than deleting its rows: a batch delete leaves
    /// the deleted rows' bytes in the SQLite free pages and the WAL. `sweep` runs while no store is
    /// attached, so it may remove the store files and the external-blob directory with the rest.
    /// `LocalDataWipe` only.
    func replaceStoreWithEmpty(sweep: () -> Void) {
        let coordinator = container.persistentStoreCoordinator
        container.viewContext.reset()
        for store in coordinator.persistentStores {
            let url = store.url
            do {
                try coordinator.remove(store)
                if let url, url.path != "/dev/null" {
                    try coordinator.destroyPersistentStore(at: url, type: .sqlite)
                }
            } catch {
                Log.error("Core Data: could not detach the store for the wipe: \(error)", category: "Persistence")
            }
        }
        sweep()
        container.loadPersistentStores { _, error in
            if let error {
                Log.error("Core Data: empty store did not load after the wipe: \(error)", category: "Persistence")
            }
            NotificationCenter.default.post(name: .localStoreReplaced, object: nil)
        }
    }

    /// Creates a fresh background context for off-main-thread writes.
    func newBackgroundContext() -> NSManagedObjectContext {
        container.newBackgroundContext()
    }

    var isReady: Bool {
        container.viewContext.persistentStoreCoordinator != nil
    }

    var safeViewContext: NSManagedObjectContext? {
        guard isReady else { return nil }
        return container.viewContext
    }

    /// Default SQLite store URL (Application Support directory, matches NSPersistentContainer default).
    static var defaultStoreURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConstructMessenger.sqlite")
    }

    /// The files a Core Data build kept the account in, below `dir` (Application Support): the
    /// store with its WAL, shared memory and external blobs, and the per-row key database
    /// (`MessageKeyStore`) that opens its bodies. macOS stopped using them at TODO 137 step 4 and
    /// the owner chose to remove what older Desktop builds left, in the clear, rather than keep
    /// it unopened. Returns how many were there.
    @discardableResult
    static func removeLegacyStore(in dir: URL) -> Int {
        let names = [
            "ConstructMessenger.sqlite", "ConstructMessenger.sqlite-wal", "ConstructMessenger.sqlite-shm",
            ".ConstructMessenger_SUPPORT",
            "ct_secure/message_keys.sqlite", "ct_secure/message_keys.sqlite-journal",
        ]
        var removed = 0
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                Log.error("Legacy store: could not remove \(name): \(error)", category: "Persistence")
            }
        }
        if removed > 0 { Log.info("Legacy store: removed \(removed) file(s)", category: "Persistence") }
        return removed
    }

    /// Removes SQLite main file + WAL + SHM so a fresh empty store can be created.
    static func nukeSQLiteFiles(at storeURL: URL) {
        let fm = FileManager.default
        for url in sqliteFiles(of: storeURL) {
            try? fm.removeItem(at: url)
        }
    }

    /// The store and its two sidecars. SQLite names them by appending `-wal` and `-shm` to the
    /// file name, not as an extension: until 2026-10-12 this removed `….sqlite.wal`, a file that
    /// never exists, and left the WAL behind — the recovery's new store then opened onto it.
    static func sqliteFiles(of storeURL: URL) -> [URL] {
        let dir = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        return [storeURL, dir.appendingPathComponent(name + "-wal"), dir.appendingPathComponent(name + "-shm")]
    }
}
