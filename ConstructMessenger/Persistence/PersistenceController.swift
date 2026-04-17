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
            fatalError("❌ Core Data: ConstructMessenger.momd not found in Bundle.main")
        }
        let c = NSPersistentContainer(name: "ConstructMessenger", managedObjectModel: model)

        if !inMemory {
            LocalBackupService.applyPendingRestoreIfNeeded()
        }

        if inMemory {
            c.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else if let description = c.persistentStoreDescriptions.first {
            // Automatic lightweight migration for model changes
            description.shouldInferMappingModelAutomatically = true
            description.shouldMigrateStoreAutomatically = true
            // NSFileProtection is iOS-only. macOS uses the user's login keychain and
            // APFS volume encryption — no per-file protection key is needed.
            #if os(iOS)
            description.setOption(FileProtectionType.complete as NSObject,
                                  forKey: NSPersistentStoreFileProtectionKey)
            #endif
        }

        c.loadPersistentStores { description, error in
            guard let error else { return }
            // Store failed to load — most likely a schema migration failure on iOS 26.
            // Attempt recovery: destroy the incompatible store and recreate it empty
            // so the app can start. The user loses local history but the app won't crash.
            guard let storeURL = description.url else {
                fatalError("❌ Core Data: persistent store has no URL — cannot recover: \(error)")
            }
            do {
                let coordinator = NSPersistentStoreCoordinator(managedObjectModel: c.managedObjectModel)
                try coordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
                try c.persistentStoreCoordinator.addPersistentStore(
                    ofType: NSSQLiteStoreType,
                    configurationName: nil,
                    at: storeURL,
                    options: [
                        NSMigratePersistentStoresAutomaticallyOption: true,
                        NSInferMappingModelAutomaticallyOption: true
                    ]
                )
                print("⚠️ Core Data: store was reset after migration failure — user data cleared")
            } catch {
                fatalError("❌ Core Data: persistent store recovery failed: \(error)")
            }
        }

        c.viewContext.automaticallyMergesChangesFromParent = true
        c.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container = c

        migrateExistingContactsToSynaps()
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
            print("✅ Synaps migration: \(users.count) existing contact(s) moved to Synaps")
        } catch {
            print("❌ Synaps migration failed: \(error)")
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
}
