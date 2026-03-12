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
        container = NSPersistentContainer(name: "ConstructMessenger")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else if let description = container.persistentStoreDescriptions.first {
            // Automatic lightweight migration for model changes
            description.shouldInferMappingModelAutomatically = true
            description.shouldMigrateStoreAutomatically = true
        }

        container.loadPersistentStores { _, error in
            if let error = error {
                // On first launch the store may not exist yet — that is normal.
                // A real failure (disk full, model mismatch without migration) is logged.
                print("❌ Core Data: failed to load persistent stores: \(error)")
            } else {
                print("✅ Core Data: persistent stores loaded")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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
}
