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
    static let shared = PersistenceController()

    /// In-memory store for SwiftUI previews and unit tests.
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        // iOS 26 bug: NSPersistentContainer(name:) searches ALL bundles for the momd
        // file and may find it in multiple locations (e.g. main bundle + xcframework),
        // registering NSEntityDescriptions twice. This causes "Expected X but found X"
        // type-cast crashes when fetching entities like CallRecord/CTCallRecord.
        // Fix: explicitly load the model from Bundle.main so only one copy is registered.
        guard let modelURL = Bundle.main.url(forResource: "ConstructMessenger", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
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
            let newest = (chat.messages as? Set<Message>)?.max(by: { $0.timestamp < $1.timestamp })
            if let newest {
                chat.applyPreview(text: newest.displayText, timestamp: newest.timestamp, force: true)
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

    /// Removes SQLite main file + WAL + SHM so a fresh empty store can be created.
    private static func nukeSQLiteFiles(at storeURL: URL) {
        let fm = FileManager.default
        let walURL = storeURL.appendingPathExtension("wal")
        let shmURL = storeURL.appendingPathExtension("shm")
        for url in [storeURL, walURL, shmURL] {
            try? fm.removeItem(at: url)
        }
    }
}
